import XCTest
@testable import WhereWolf

final class CoverageReportTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private func date(_ seconds: Double) -> Date { origin.addingTimeInterval(seconds) }
    private func report(_ points: [Double], _ events: [(Double, TrackingTransition.Kind)], end: Double = 3600) -> CoverageReport {
        CoverageReport.compute(timestamps: points.map(date), transitions: events.map { TrackingTransition(date: date($0.0), kind: $0.1) },
                               sends: [], start: origin, end: date(end), queued: 0)
    }
    func testRecordedPausedGapAndResumeSpans() {
        let value = report([0, 60, 120, 1800, 1860, 3600], [(0, .start), (120, .pause), (1800, .resume)])
        XCTAssertEqual(value.spans.map(\.kind), [.recorded, .paused, .recorded, .gap])
        XCTAssertEqual(value.spans[1].start, date(120)); XCTAssertEqual(value.spans[1].end, date(1800))
        XCTAssertEqual(value.gaps.first?.start, date(1860)); XCTAssertEqual(value.longestGap, 1740)
        XCTAssertEqual(value.spans.reduce(0) { $0 + $1.duration }, 3600)
    }
    func testTenMinuteThresholdIsStrict() {
        XCTAssertTrue(report([0, 600], [(0, .start)], end: 600).gaps.isEmpty)
        XCTAssertEqual(report([0, 601], [(0, .start)], end: 601).longestGap, 601)
        XCTAssertTrue(report([], [(0, .start)], end: 600).gaps.isEmpty)
        XCTAssertEqual(report([], [(0, .start)], end: 601).longestGap, 601)
    }
    func testAnIsolatedAcceptedFixSeparatesTwoGaps() {
        let value = report([0, 601], [(0, .start)], end: 1202)
        XCTAssertEqual(value.gaps.count, 2)
        XCTAssertEqual(value.gaps.map(\.duration), [601, 601])
        XCTAssertEqual(value.longestGap, 601)
    }
    func testStopAndOffArePausedNeverGaps() {
        let value = report([0], [(0, .stop)])
        XCTAssertEqual(value.spans.map(\.kind), [.paused]); XCTAssertTrue(value.gaps.isEmpty)
    }
    func testUnknownBeforeFirstTransitionIsExplicit() {
        let value = report([], [(1800, .start)])
        XCTAssertEqual(value.spans.map(\.kind), [.unknown, .gap])
        XCTAssertEqual(value.gaps.first?.start, date(1800))
    }
    func testWindowClipsPriorGapAndPreservesPriorPause() {
        let gap = report([-600], [(-1200, .start)], end: 1200)
        XCTAssertEqual(gap.longestGap, 1200)
        XCTAssertEqual(report([], [(-1200, .pause)]).spans.map(\.kind), [.paused])
    }
    func testTotalsHourlyPointsSendWindowAndQueue() {
        let sends = [CoverageSend(date: date(-1), status: 0), CoverageSend(date: date(10), status: 0),
                     CoverageSend(date: date(20), status: 1, error: "Server Error"), CoverageSend(date: date(30), status: 2)]
        let value = CoverageReport.compute(timestamps: [date(3601), date(1), date(2)], transitions: [TrackingTransition(date: origin, kind: .start)],
            sends: sends, start: origin, end: date(7200), queued: 17)
        XCTAssertEqual(value.pointCount, 3); XCTAssertEqual(value.hours.reduce(0) { $0 + $1.points }, 3)
        XCTAssertEqual(value.sendsSucceeded, 1); XCTAssertEqual(value.sendsFailed, 2)
        XCTAssertEqual(value.lastError, "Network failure"); XCTAssertEqual(value.queued, 17)
    }
    func testBoundsRetainOneStateAtCutoffAndTwoThousandTransitions() {
        let events = (0..<2500).map { TrackingTransition(date: date(Double($0)), kind: $0.isMultiple(of: 2) ? .pause : .resume) }
        let value = TrackingTransitionLog.bounded(CoverageLogSnapshot(transitions: events), cutoff: date(1))
        XCTAssertEqual(value.transitions.count, 2000); XCTAssertEqual(value.transitions.first?.date, date(500))
        let anchor = TrackingTransitionLog.bounded(CoverageLogSnapshot(transitions: [TrackingTransition(date: date(-100), kind: .pause)]), cutoff: origin)
        XCTAssertEqual(anchor.transitions, [TrackingTransition(date: origin, kind: .pause)])
    }
    func testSendBoundsAndRetention() {
        let sends = (0..<21000).map { CoverageSend(date: date(Double($0)), status: 0) }
        let value = TrackingTransitionLog.bounded(CoverageLogSnapshot(sends: sends), cutoff: date(200))
        XCTAssertEqual(value.sends.count, 20000); XCTAssertEqual(value.sends.first?.date, date(1000))
    }
    func testTransitionLogDeduplicatesAndPersistsWithoutCoordinates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = TrackingTransitionLog(directory: directory, retention: { 86400 }, clock: { self.date(1000) })
        log.record(tracking: true, paused: false, date: origin)
        log.record(tracking: true, paused: false, date: date(1))
        log.record(tracking: true, paused: true, date: date(2))
        log.record(tracking: true, paused: false, date: date(3))
        log.record(tracking: false, paused: false, date: date(4))
        let value = await withCheckedContinuation { continuation in log.load { continuation.resume(returning: $0) } }
        XCTAssertEqual(value.transitions.map(\.kind), [.start, .pause, .resume, .stop])
        let json = try String(contentsOf: directory.appendingPathComponent("state.json"), encoding: .utf8)
        XCTAssertFalse(json.contains("latitude")); XCTAssertFalse(json.contains("longitude")); XCTAssertFalse(json.contains("server"))
        let resource = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(resource.isExcludedFromBackup, true)
    }
}
