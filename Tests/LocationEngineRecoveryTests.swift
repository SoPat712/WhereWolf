import CoreLocation
import Foundation
import XCTest
@testable import WhereWolf

@MainActor
final class LocationEngineRecoveryTests: XCTestCase {
    private enum StreamError: Error {
        case ended
    }

    private enum StreamMode {
        case failing
        case holding
    }

    @MainActor
    private final class StreamSource {
        var mode: StreamMode
        private(set) var calls = 0
        private(set) var continuations: [AsyncThrowingStream<CLLocationUpdate, Error>.Continuation] = []

        init(mode: StreamMode) {
            self.mode = mode
        }

        func make(_ configuration: CLLocationUpdate.LiveConfiguration) -> AsyncThrowingStream<CLLocationUpdate, Error> {
            _ = configuration
            calls += 1
            switch mode {
            case .failing:
                return AsyncThrowingStream { continuation in
                    continuation.finish(throwing: StreamError.ended)
                }
            case .holding:
                return AsyncThrowingStream { continuation in
                    continuations.append(continuation)
                }
            }
        }

        func finish(_ index: Int, with error: Error? = nil) {
            guard continuations.indices.contains(index) else { return }
            if let error {
                continuations[index].finish(throwing: error)
            } else {
                continuations[index].finish()
            }
        }
    }

    @MainActor
    private final class RetryRecorder {
        private(set) var delays: [Duration] = []

        func sleep(_ duration: Duration) async throws {
            delays.append(duration)
            await Task.yield()
        }
    }

    @MainActor
    private final class BackgroundSession: _WhereWolfLocationBackgroundSession {
        private(set) var invalidations = 0

        func invalidate() {
            invalidations += 1
        }
    }

    @MainActor
    private final class EngineState {
        var trackingEnabled = true
        var pausedByRadius = false
    }

    func testTerminalFailureLatchesAfterFourAttemptsAndNotifiesAfterCleanup() async {
        let source = StreamSource(mode: .failing)
        let recorder = RetryRecorder()
        let session = BackgroundSession()
        let engine = makeEngine(source: source, recorder: recorder, session: session)
        var notifications = 0
        var observedCleanup = false
        let observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("WhereWolfLiveUpdatesFailed"), object: engine, queue: .main
        ) { _ in
            notifications += 1
            observedCleanup = !engine.usingLiveUpdates
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        XCTAssertTrue(engine.prepareLiveUpdates(backgroundIndicator: true))
        engine.runLiveUpdates(activityType: 1)
        await waitUntil { engine.liveUpdatesFailed }

        XCTAssertTrue(engine.liveUpdatesFailed)
        XCTAssertFalse(engine.usingLiveUpdates)
        XCTAssertEqual(source.calls, 4)
        XCTAssertEqual(recorder.delays, [.seconds(1), .seconds(2), .seconds(4)])
        XCTAssertEqual(notifications, 1)
        XCTAssertTrue(observedCleanup)

        XCTAssertFalse(engine.prepareLiveUpdates(backgroundIndicator: true))
        XCTAssertEqual(session.invalidations, 1)
        await Task.yield()
        XCTAssertEqual(notifications, 1)
    }

    func testSuccessfulStreamContinuationDoesNotRetryOrLatch() async {
        let source = StreamSource(mode: .holding)
        let recorder = RetryRecorder()
        let engine = makeEngine(source: source, recorder: recorder)

        engine.runLiveUpdates(activityType: 1)
        await waitUntil { source.calls == 1 && engine.usingLiveUpdates }

        XCTAssertFalse(engine.liveUpdatesFailed)
        XCTAssertEqual(source.calls, 1)
        XCTAssertTrue(recorder.delays.isEmpty)
        engine.stopLiveUpdates()
        await Task.yield()
        XCTAssertFalse(engine.usingLiveUpdates)
        XCTAssertFalse(engine.liveUpdatesFailed)
    }

    func testCanceledReplacementCannotReportStaleFailureOrClearCurrentStream() async {
        let source = StreamSource(mode: .holding)
        let recorder = RetryRecorder()
        let engine = makeEngine(source: source, recorder: recorder)
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("WhereWolfLiveUpdatesFailed"), object: engine, queue: .main
        ) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        engine.runLiveUpdates(activityType: 1)
        await waitUntil { source.calls == 1 && engine.usingLiveUpdates }
        engine.runLiveUpdates(activityType: 2)
        await waitUntil { source.calls == 2 && engine.usingLiveUpdates }

        source.finish(0, with: StreamError.ended)
        await Task.yield()
        XCTAssertTrue(engine.usingLiveUpdates)
        XCTAssertFalse(engine.liveUpdatesFailed)
        XCTAssertEqual(notifications, 0)
        engine.stopLiveUpdates()
    }

    func testResetAllowsAnExplicitRetryAfterTerminalFailure() async {
        let source = StreamSource(mode: .failing)
        let recorder = RetryRecorder()
        let engine = makeEngine(source: source, recorder: recorder)
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("WhereWolfLiveUpdatesFailed"), object: engine, queue: .main
        ) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        engine.runLiveUpdates(activityType: 1)
        await waitUntil { engine.liveUpdatesFailed }
        XCTAssertEqual(notifications, 1)

        engine.resetLiveUpdatesFailure()
        XCTAssertFalse(engine.liveUpdatesFailed)
        source.mode = .holding
        engine.runLiveUpdates(activityType: 1)
        await waitUntil { source.calls == 5 && engine.usingLiveUpdates }
        XCTAssertFalse(engine.liveUpdatesFailed)
        XCTAssertEqual(notifications, 1)
        engine.stopLiveUpdates()
    }

    func testDeniedAuthorizationNeverStartsOrLatches() async {
        let source = StreamSource(mode: .failing)
        let recorder = RetryRecorder()
        let engine = makeEngine(source: source, recorder: recorder, authorization: .denied)

        engine.runLiveUpdates(activityType: 1)
        await waitUntil { !engine.usingLiveUpdates }

        XCTAssertFalse(engine.usingLiveUpdates)
        XCTAssertFalse(engine.liveUpdatesFailed)
        XCTAssertEqual(source.calls, 0)
    }

    func testUndeterminedAuthorizationNeverStartsOrLatches() async {
        let source = StreamSource(mode: .failing)
        let recorder = RetryRecorder()
        let engine = makeEngine(source: source, recorder: recorder, authorization: .notDetermined)

        engine.runLiveUpdates(activityType: 1)
        await waitUntil { !engine.usingLiveUpdates }

        XCTAssertFalse(engine.liveUpdatesFailed)
        XCTAssertEqual(source.calls, 0)
    }

    func testTrackingOffNeverStartsOrLatches() async {
        let source = StreamSource(mode: .failing)
        let recorder = RetryRecorder()
        let state = EngineState()
        state.trackingEnabled = false
        let engine = makeEngine(source: source, recorder: recorder, state: state)

        engine.runLiveUpdates(activityType: 1)
        await waitUntil { !engine.usingLiveUpdates }

        XCTAssertFalse(engine.usingLiveUpdates)
        XCTAssertFalse(engine.liveUpdatesFailed)
        XCTAssertEqual(source.calls, 0)
    }

    func testTrackingTurningOffDuringAStreamCannotLatch() async {
        let source = StreamSource(mode: .holding)
        let recorder = RetryRecorder()
        let state = EngineState()
        let engine = makeEngine(source: source, recorder: recorder, state: state)

        engine.runLiveUpdates(activityType: 1)
        await waitUntil { source.calls == 1 && engine.usingLiveUpdates }
        state.trackingEnabled = false
        source.finish(0, with: StreamError.ended)
        await waitUntil { !engine.usingLiveUpdates }

        XCTAssertFalse(engine.liveUpdatesFailed)
        XCTAssertTrue(recorder.delays.isEmpty)
    }

    func testRadiusPauseDuringAStreamCannotLatch() async {
        let source = StreamSource(mode: .holding)
        let recorder = RetryRecorder()
        let state = EngineState()
        let engine = makeEngine(source: source, recorder: recorder, state: state)

        engine.runLiveUpdates(activityType: 1)
        await waitUntil { source.calls == 1 && engine.usingLiveUpdates }
        state.pausedByRadius = true
        source.finish(0, with: StreamError.ended)
        await waitUntil { !engine.usingLiveUpdates }

        XCTAssertFalse(engine.liveUpdatesFailed)
        XCTAssertTrue(recorder.delays.isEmpty)
    }

    private func makeEngine(
        source: StreamSource,
        recorder: RetryRecorder,
        session: BackgroundSession? = nil,
        state: EngineState? = nil,
        authorization: CLAuthorizationStatus = .authorizedAlways
    ) -> WhereWolfLocationEngine {
        let state = state ?? EngineState()
        let session = session ?? BackgroundSession()
        let dependencies = WhereWolfLocationEngine.Dependencies(
            liveUpdates: source.make,
            sleep: recorder.sleep,
            trackingEnabled: { state.trackingEnabled },
            didPauseByRadius: { state.pausedByRadius },
            hasBackgroundLocationActivity: { false },
            processLocation: { _ in },
            processStationary: { _ in },
            makeBackgroundSession: { session }
        )
        return WhereWolfLocationEngine(dependencies: dependencies, authorization: authorization)
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for location engine state")
    }
}
