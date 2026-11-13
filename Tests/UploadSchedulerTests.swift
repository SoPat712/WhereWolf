import Foundation
import UIKit
import XCTest
@testable import WhereWolf

@MainActor
final class UploadSchedulerTests: XCTestCase {
    func testSendIntentAwaitsFirstBatchResult() async throws {
        let started = expectation(description: "Send started")
        var complete: ((Error?) -> Void)?
        var returned = false
        let task = Task {
            try await SendNowIntent.awaitFirstBatch { callback in
                complete = callback
                started.fulfill()
            }
            returned = true
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(returned)
        let callback = try XCTUnwrap(complete)
        callback(nil)
        try await task.value
        XCTAssertTrue(returned)
    }

    func testSendIntentThrowsDestinationTimeoutAndBatchErrors() async {
        for code in [1, 2, 3] {
            let failure = NSError(domain: "WhereWolf.Send", code: code,
                                userInfo: [NSLocalizedDescriptionKey: "Send could not finish"])
            do {
                try await SendNowIntent.awaitFirstBatch { $0(failure) }
                XCTFail("The intent must report a send error")
            } catch {
                XCTAssertEqual(error as NSError, failure)
            }
        }
    }

    private func settle() async {
        await Task.yield()
        await Task.yield()
    }

    @MainActor
    private final class FakeTask: _WhereWolfUploadSchedulerTask {
        var expirationHandler: (() -> Void)?
        private(set) var completionResults: [Bool] = []

        func setTaskCompleted(success: Bool) {
            completionResults.append(success)
        }
    }

    @MainActor
    private final class FakePathMonitor: _WhereWolfUploadSchedulerPathMonitor {
        var onPathUpdate: ((Bool) -> Void)?
        private(set) var startCount = 0
        private(set) var cancelCount = 0

        func start() {
            startCount += 1
        }

        func cancel() {
            cancelCount += 1
            onPathUpdate = nil
        }

        func emit(_ satisfied: Bool) {
            onPathUpdate?(satisfied)
        }
    }

    @MainActor
    private final class Harness {
        let center = NotificationCenter()
        let path = FakePathMonitor()
        var now = Date(timeIntervalSince1970: 1_000)
        var state = _WhereWolfUploadSchedulerState()
        var registeredHandler: _WhereWolfUploadSchedulerDependencies.TaskHandler?
        var submittedDates: [Date] = []
        var cancelCount = 0
        var pendingUploadCalls = 0
        var connectivityRecoveryCalls = 0

        func dependencies() -> _WhereWolfUploadSchedulerDependencies {
            _WhereWolfUploadSchedulerDependencies(
                identifier: { "test.wherewolf.upload" },
                now: { [weak self] in self?.now ?? Date(timeIntervalSince1970: 1_000) },
                state: { [weak self] in self?.state ?? _WhereWolfUploadSchedulerState() },
                register: { [weak self] _, handler in
                    self?.registeredHandler = handler
                    return true
                },
                submit: { [weak self] _, date in
                    self?.submittedDates.append(date)
                },
                cancel: { [weak self] _ in
                    self?.cancelCount += 1
                },
                makePathMonitor: { [weak self] in
                    self?.path ?? FakePathMonitor()
                },
                resumePendingUpload: { [weak self] in
                    self?.pendingUploadCalls += 1
                },
                resumeUploadAfterConnectivity: { [weak self] in
                    self?.connectivityRecoveryCalls += 1
                },
                notificationCenter: center,
                sleep: { duration in
                    try await Task.sleep(for: duration)
                }
            )
        }

        func post(_ name: String) {
            center.post(name: Notification.Name(name), object: nil)
        }
    }

    private func makeScheduler(_ harness: Harness) -> WhereWolfUploadScheduler {
        WhereWolfUploadScheduler(dependencies: harness.dependencies())
    }

    func testAsynchronousStatusChangesNotifyTheSettingsObserver() async {
        let harness = Harness()
        let scheduler = makeScheduler(harness)
        var statuses: [String] = []
        let observer = harness.center.addObserver(
            forName: WhereWolfUploadScheduler.stateChangedNotification, object: scheduler, queue: .main
        ) { _ in statuses.append(scheduler.status) }
        defer {
            harness.center.removeObserver(observer)
            scheduler.stopForTesting()
        }
        scheduler.start()
        harness.state.backgroundUploadsEnabled = true
        harness.post(GLSettingsChangedNotification)
        await settle()
        XCTAssertEqual(statuses, ["Off", "Idle"])
        harness.state.pendingUploads = true
        harness.post(GLUploadStateChangedNotification)
        await settle()
        XCTAssertEqual(statuses.last, "Scheduled")
    }

    func testDisabledOptionCancelsScheduledWorkAndLeavesForegroundRecoveryAvailable() async {
        let harness = Harness()
        harness.state.pendingUploads = true
        let scheduler = makeScheduler(harness)
        scheduler.start()
        XCTAssertEqual(harness.submittedDates.count, 0)
        XCTAssertEqual(scheduler.status, "Off")

        harness.post(UIApplication.didBecomeActiveNotification.rawValue)
        await settle()
        XCTAssertEqual(harness.pendingUploadCalls, 1)

        harness.state.backgroundUploadsEnabled = true
        harness.post(GLSettingsChangedNotification)
        await settle()
        XCTAssertEqual(harness.submittedDates.count, 1)

        harness.state.backgroundUploadsEnabled = false
        harness.post(GLSettingsChangedNotification)
        await settle()
        XCTAssertEqual(harness.cancelCount, 2)
        XCTAssertEqual(scheduler.status, "Off")
        scheduler.stopForTesting()
    }

    func testEquivalentNotificationsCoalesceSchedulingPlans() async {
        let harness = Harness()
        harness.state.backgroundUploadsEnabled = true
        harness.state.pendingUploads = true
        let scheduler = makeScheduler(harness)
        scheduler.start()
        XCTAssertEqual(harness.submittedDates.count, 1)
        let initialCancellations = harness.cancelCount

        harness.post(GLSettingsChangedNotification)
        await settle()
        harness.post(GLUploadStateChangedNotification)
        await settle()
        harness.post(GLSendingFinishedNotification)
        await settle()
        harness.now.addTimeInterval(10)
        harness.post(GLUploadStateChangedNotification)
        await settle()

        XCTAssertEqual(harness.submittedDates.count, 1)
        XCTAssertEqual(harness.cancelCount, initialCancellations)
        scheduler.stopForTesting()
    }

    func testRetryDateIsHonoredButNeverSchedulesEarlierThanMinimumDelay() async {
        let harness = Harness()
        harness.state.backgroundUploadsEnabled = true
        harness.state.pendingUploads = true
        harness.state.uploadRetryDate = harness.now.addingTimeInterval(5)
        let scheduler = makeScheduler(harness)
        scheduler.start()
        XCTAssertEqual(harness.submittedDates.first, harness.now.addingTimeInterval(60))
        let initialCancellations = harness.cancelCount

        harness.state.uploadRetryDate = harness.now.addingTimeInterval(120)
        harness.post(GLUploadStateChangedNotification)
        await settle()
        XCTAssertEqual(harness.cancelCount, initialCancellations + 1)
        XCTAssertEqual(harness.submittedDates.count, 2)
        XCTAssertEqual(harness.submittedDates.last, harness.now.addingTimeInterval(120))
        scheduler.stopForTesting()
    }

    func testNoPendingQueueDoesNotSubmitBackgroundWork() async {
        let harness = Harness()
        harness.state.backgroundUploadsEnabled = true
        let scheduler = makeScheduler(harness)
        scheduler.start()
        XCTAssertEqual(harness.submittedDates.count, 0)
        XCTAssertEqual(scheduler.status, "Idle")
        scheduler.stopForTesting()
    }

    func testActiveTaskWaitsForQueueStateInsteadOfFinishingOnTransientIdleSendState() async {
        let harness = Harness()
        harness.state.backgroundUploadsEnabled = true
        harness.state.pendingUploads = true
        let scheduler = makeScheduler(harness)
        scheduler.start()
        let task = FakeTask()
        harness.registeredHandler?(task)
        await settle()
        XCTAssertEqual(harness.pendingUploadCalls, 1)
        XCTAssertTrue(task.completionResults.isEmpty)

        harness.state.sendInProgress = false
        harness.post(GLSendingFinishedNotification)
        await settle()
        // The core schedules the next drain batch, including its bounded yield.
        XCTAssertEqual(harness.pendingUploadCalls, 1)
        XCTAssertTrue(task.completionResults.isEmpty)

        harness.state.pendingUploads = false
        harness.post(GLUploadStateChangedNotification)
        await settle()
        XCTAssertEqual(task.completionResults, [true])
        scheduler.stopForTesting()
    }

    func testExpirationCompletesOnceAndReschedulesPendingWork() async {
        let harness = Harness()
        harness.state.backgroundUploadsEnabled = true
        harness.state.pendingUploads = true
        let scheduler = makeScheduler(harness)
        scheduler.start()
        let task = FakeTask()
        harness.registeredHandler?(task)
        await settle()
        XCTAssertEqual(harness.submittedDates.count, 1)

        task.expirationHandler?()
        await settle()
        XCTAssertEqual(task.completionResults, [false])
        XCTAssertEqual(harness.submittedDates.count, 2)

        task.expirationHandler?()
        scheduler.expireActiveTaskForTesting()
        XCTAssertEqual(task.completionResults, [false])
        scheduler.stopForTesting()
    }

    func testConnectivityRecoveryOnlyRunsOnUnsatisfiedToSatisfiedTransition() async {
        let harness = Harness()
        harness.state.pendingUploads = true
        harness.state.connectivityRetryEnabled = true
        let scheduler = makeScheduler(harness)
        scheduler.start()
        XCTAssertEqual(harness.path.startCount, 1)

        harness.path.emit(true)
        harness.path.emit(true)
        harness.path.emit(false)
        harness.path.emit(true)
        harness.path.emit(true)
        await settle()
        XCTAssertEqual(harness.connectivityRecoveryCalls, 1)

        harness.state.connectivityRetryEnabled = false
        harness.post(GLSettingsChangedNotification)
        await settle()
        XCTAssertEqual(harness.path.cancelCount, 1)
        harness.path.emit(true)
        XCTAssertEqual(harness.connectivityRecoveryCalls, 1)
        scheduler.stopForTesting()
    }
}
