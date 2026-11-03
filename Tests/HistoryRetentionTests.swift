import Foundation
import XCTest
@testable import WhereWolf

final class HistoryRetentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let suiteNameKey = "HistoryRetentionTestsSuiteName"

    func testRetentionDefaultsBoundsAndPersistence() {
        let (defaults, store, directory) = makeStore()
        defer { cleanup(defaults: defaults, directory: directory) }

        XCTAssertEqual(HistoryRetention.hours(using: defaults), HistoryRetention.defaultHours)
        defaults.set(-1, forKey: HistoryRetention.userDefaultsKey)
        XCTAssertEqual(HistoryRetention.hours(using: defaults), HistoryRetention.minimumHours)
        defaults.set(10_000, forKey: HistoryRetention.userDefaultsKey)
        XCTAssertEqual(HistoryRetention.hours(using: defaults), HistoryRetention.maximumHours)

        store.setRetentionHours(72)
        _ = load(store)
        XCTAssertEqual(HistoryRetention.hours(using: defaults), 72)
        XCTAssertEqual(HistoryRetention.duration(using: defaults), 72 * 60 * 60)
    }

    func testSevenDayRetentionSurvivesAndOlderHistoryExpires() {
        let (defaults, store, directory) = makeStore(hours: HistoryRetention.maximumHours)
        defer { cleanup(defaults: defaults, directory: directory) }

        record(store, timestamp: now.addingTimeInterval(-6 * 24 * 60 * 60))
        record(store, timestamp: now.addingTimeInterval(-8 * 24 * 60 * 60))

        let points = load(store)
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].timestamp, now.addingTimeInterval(-6 * 24 * 60 * 60))
    }

    func testShrinkingRetentionPrunesImmediately() {
        let (defaults, store, directory) = makeStore(hours: HistoryRetention.maximumHours)
        defer { cleanup(defaults: defaults, directory: directory) }

        record(store, timestamp: now.addingTimeInterval(-2 * 24 * 60 * 60))
        record(store, timestamp: now.addingTimeInterval(-12 * 60 * 60))
        XCTAssertEqual(load(store).count, 2)

        store.setRetentionHours(HistoryRetention.minimumHours)
        let points = load(store)
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].timestamp, now.addingTimeInterval(-12 * 60 * 60))
    }

    func testIncreasingRetentionCannotResurrectDeletedHistory() {
        let (defaults, store, directory) = makeStore(hours: HistoryRetention.maximumHours)
        defer { cleanup(defaults: defaults, directory: directory) }

        record(store, timestamp: now.addingTimeInterval(-2 * 24 * 60 * 60))
        record(store, timestamp: now.addingTimeInterval(-12 * 60 * 60))
        store.setRetentionHours(HistoryRetention.minimumHours)
        XCTAssertEqual(load(store).count, 1)

        store.setRetentionHours(HistoryRetention.maximumHours)
        XCTAssertEqual(load(store).count, 1)
    }

    func testStorageSummaryUsesAggregatePayloadAndDatabaseSidecars() {
        let (defaults, store, directory) = makeStore()
        defer { cleanup(defaults: defaults, directory: directory) }

        record(store, timestamp: now.addingTimeInterval(-60))
        record(store, timestamp: now.addingTimeInterval(-30))
        _ = load(store)

        let summary = storageSummary(store)
        XCTAssertEqual(summary.pointCount, 2)
        XCTAssertGreaterThan(summary.averagePayloadBytes, 0)
        XCTAssertGreaterThan(summary.storageBytes, 0)
    }

    func testIndependentStoresKeepRowsAndPoliciesSeparate() {
        let firstDefaults = makeDefaults()
        let secondDefaults = makeDefaults()
        let firstDirectory = makeDirectory()
        let secondDirectory = makeDirectory()
        let first = RecentLocationHistory(directoryURL: firstDirectory, defaults: firstDefaults, clock: { self.now })
        let second = RecentLocationHistory(directoryURL: secondDirectory, defaults: secondDefaults, clock: { self.now })
        defer {
            cleanup(defaults: firstDefaults, directory: firstDirectory)
            cleanup(defaults: secondDefaults, directory: secondDirectory)
        }

        first.setRetentionHours(HistoryRetention.maximumHours)
        _ = load(first)
        second.setRetentionHours(HistoryRetention.minimumHours)
        _ = load(second)
        record(first, timestamp: now.addingTimeInterval(-2 * 24 * 60 * 60))
        record(second, timestamp: now.addingTimeInterval(-2 * 24 * 60 * 60))

        XCTAssertEqual(load(first).count, 1)
        XCTAssertEqual(load(second).count, 0)
    }

    func testRetentionNotificationArrivesAfterQueuedPrune() {
        let (defaults, store, directory) = makeStore(hours: HistoryRetention.maximumHours)
        defer { cleanup(defaults: defaults, directory: directory) }
        record(store, timestamp: now.addingTimeInterval(-2 * 24 * 60 * 60))

        let notification = expectation(description: "retention changed")
        let observer = NotificationCenter.default.addObserver(
            forName: .recentLocationHistoryRetentionChanged, object: nil, queue: .main
        ) { _ in notification.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }
        store.setRetentionHours(HistoryRetention.minimumHours)
        _ = load(store)
        wait(for: [notification], timeout: 2)
        XCTAssertEqual(load(store).count, 0)
    }

    private func makeStore(hours: Int = HistoryRetention.defaultHours) -> (UserDefaults, RecentLocationHistory, URL) {
        let defaults = makeDefaults()
        defaults.set(hours, forKey: HistoryRetention.userDefaultsKey)
        let directory = makeDirectory()
        let store = RecentLocationHistory(directoryURL: directory, defaults: defaults, clock: { self.now })
        return (defaults, store, directory)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "WhereWolf.HistoryRetentionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(suite, forKey: suiteNameKey)
        return defaults
    }

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WhereWolf.HistoryRetentionTests.\(UUID().uuidString)", isDirectory: true)
    }

    private func record(_ store: RecentLocationHistory, timestamp: Date) {
        store.recordUpdate([
            "_type": "location",
            "lat": 45.5152,
            "lon": -122.6784,
            "tst": timestamp.timeIntervalSince1970,
            "topic": "history-test"
        ] as NSDictionary)
        _ = load(store)
    }

    private func load(_ store: RecentLocationHistory) -> [RecordedLocation] {
        var result = [RecordedLocation]()
        let finished = expectation(description: "history loaded")
        store.load(after: 0) {
            result = $0
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
        return result
    }

    private func storageSummary(_ store: RecentLocationHistory) -> HistoryStorageSummary {
        var result = HistoryStorageSummary(pointCount: 0, storageBytes: 0, averagePayloadBytes: 0)
        let finished = expectation(description: "storage summary loaded")
        store.loadStorageSummary {
            result = $0
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
        return result
    }

    private func cleanup(defaults: UserDefaults, directory: URL) {
        if let suite = defaults.string(forKey: suiteNameKey) {
            defaults.removePersistentDomain(forName: suite)
        }
        try? FileManager.default.removeItem(at: directory)
    }
}
