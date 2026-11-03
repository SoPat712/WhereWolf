import BackgroundTasks
import Foundation
import Network
import UIKit

@MainActor
protocol _WhereWolfUploadSchedulerTask: AnyObject {
    var expirationHandler: (() -> Void)? { get set }
    func setTaskCompleted(success: Bool)
}

@MainActor
protocol _WhereWolfUploadSchedulerPathMonitor: AnyObject {
    var onPathUpdate: ((Bool) -> Void)? { get set }
    func start()
    func cancel()
}

struct _WhereWolfUploadSchedulerState: Equatable {
    var backgroundUploadsEnabled = false
    var connectivityRetryEnabled = false
    var pendingUploads = false
    var uploadsBlocked = false
    var uploadRetryDate: Date?
    var sendInProgress = false
    // Counts as blocked too, so no background task runs only to find it cannot send.
    var waitingForWifi = false
}

struct _WhereWolfUploadSchedulerDependencies {
    typealias TaskHandler = @MainActor (_ task: _WhereWolfUploadSchedulerTask) -> Void

    let identifier: @MainActor () -> String
    let now: @MainActor () -> Date
    let state: @MainActor () -> _WhereWolfUploadSchedulerState
    let register: @MainActor (_ identifier: String, _ handler: @escaping TaskHandler) -> Bool
    let submit: @MainActor (_ identifier: String, _ earliestDate: Date) throws -> Void
    let cancel: @MainActor (_ identifier: String) -> Void
    let makePathMonitor: @MainActor () -> _WhereWolfUploadSchedulerPathMonitor
    let resumePendingUpload: @MainActor () -> Void
    let resumeUploadAfterConnectivity: @MainActor () -> Void
    let notificationCenter: NotificationCenter
    let sleep: @MainActor (Duration) async throws -> Void

    static func production() -> Self {
        Self(
            identifier: {
                if let identifier = Bundle.main.object(forInfoDictionaryKey: "WhereWolfBackgroundUploadIdentifier") as? String,
                   !identifier.isEmpty {
                    return identifier
                }
                return (Bundle.main.bundleIdentifier ?? "WhereWolf") + ".upload"
            },
            now: { Date() },
            state: {
                guard let gl = GLManager.shared() else { return _WhereWolfUploadSchedulerState() }
                let options = gl.advancedTrackingOptions ?? [:]
                return _WhereWolfUploadSchedulerState(
                    backgroundUploadsEnabled: options["background_uploads"]?.boolValue ?? false,
                    connectivityRetryEnabled: options["connectivity_retry"]?.boolValue ?? false,
                    pendingUploads: gl.pendingUploads,
                    uploadsBlocked: gl.uploadsBlocked || gl.waitingForWifi,
                    uploadRetryDate: gl.uploadRetryDate,
                    sendInProgress: gl.sendInProgress,
                    waitingForWifi: gl.waitingForWifi
                )
            },
            register: { identifier, handler in
                BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
                    guard task is BGProcessingTask else {
                        task.setTaskCompleted(success: false)
                        return
                    }
                    Task { @MainActor in
                        handler(SystemUploadSchedulerTask(task))
                    }
                }
            },
            submit: { identifier, earliestDate in
                let request = BGProcessingTaskRequest(identifier: identifier)
                request.requiresNetworkConnectivity = true
                request.requiresExternalPower = false
                request.earliestBeginDate = earliestDate
                try BGTaskScheduler.shared.submit(request)
            },
            cancel: { identifier in
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            },
            makePathMonitor: { SystemUploadSchedulerPathMonitor() },
            resumePendingUpload: { GLManager.shared()?.resumePendingUpload() },
            resumeUploadAfterConnectivity: { GLManager.shared()?.resumeUploadAfterConnectivity() },
            notificationCenter: .default,
            sleep: { duration in try await Task.sleep(for: duration) }
        )
    }
}

@MainActor
private final class SystemUploadSchedulerTask: _WhereWolfUploadSchedulerTask {
    private let task: BGTask

    init(_ task: BGTask) {
        self.task = task
    }

    var expirationHandler: (() -> Void)? {
        get { task.expirationHandler }
        set { task.expirationHandler = newValue }
    }

    func setTaskCompleted(success: Bool) {
        task.setTaskCompleted(success: success)
    }
}

@MainActor
private final class SystemUploadSchedulerPathMonitor: _WhereWolfUploadSchedulerPathMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "me.joshpatra.WhereWolf.upload-connectivity")
    var onPathUpdate: ((Bool) -> Void)?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                self?.onPathUpdate?(satisfied)
            }
        }
    }

    func start() {
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
        onPathUpdate = nil
    }
}

@MainActor
@objc final class WhereWolfUploadScheduler: NSObject {
    @objc static let shared = WhereWolfUploadScheduler()
    static let stateChangedNotification = Notification.Name("WhereWolfUploadSchedulerStateChanged")

    private struct SchedulePlan: Equatable {
        let retryDate: Date?
    }

    private let dependencies: _WhereWolfUploadSchedulerDependencies
    private let activeDeadline: Duration = .seconds(25)
    private var started = false
    private var registered = false
    private var observerTokens: [NSObjectProtocol] = []
    private var scheduledPlan: SchedulePlan?
    private var cancellationEnsured = false
    private var activeTask: _WhereWolfUploadSchedulerTask?
    private var activeDeadlineTask: Task<Void, Never>?
    private var pathMonitor: _WhereWolfUploadSchedulerPathMonitor?
    private var pathHasValue = false
    private var pathSatisfied = false
    private var statusValue = "Not started" {
        didSet {
            if statusValue != oldValue {
                dependencies.notificationCenter.post(name: Self.stateChangedNotification, object: self)
            }
        }
    }

    init(dependencies: _WhereWolfUploadSchedulerDependencies = .production()) {
        self.dependencies = dependencies
        super.init()
    }

    @objc var status: String { statusValue }

    @objc func start() {
        guard !started else { return }
        started = true
        let identifier = dependencies.identifier()
        registered = dependencies.register(identifier) { [weak self] task in
            Task { @MainActor in
                self?.handle(task)
            }
        }
        installObservers()
        reconcile()
    }

    private func installObservers() {
        let center = dependencies.notificationCenter
        for name in [GLSettingsChangedNotification, GLUploadStateChangedNotification, GLSendingFinishedNotification] {
            observerTokens.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) {
                [weak self] notification in
                Task { @MainActor in
                    self?.receive(notification.name)
                }
            })
        }
        for name in [UIApplication.willEnterForegroundNotification, UIApplication.didBecomeActiveNotification] {
            observerTokens.append(center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] notification in
                Task { @MainActor in
                    self?.foregroundRecovery(notification.name)
                }
            })
        }
    }

    private func receive(_ name: Notification.Name) {
        configurePathMonitor(for: dependencies.state())
        if activeTask != nil {
            evaluateActiveTask(allowResume: false)
        } else {
            reconcile()
        }
    }

    private func foregroundRecovery(_ name: Notification.Name) {
        let state = dependencies.state()
        configurePathMonitor(for: state)
        if state.pendingUploads && !state.uploadsBlocked {
            dependencies.resumePendingUpload()
        }
        if activeTask != nil {
            evaluateActiveTask(allowResume: false)
        } else {
            reconcile()
        }
    }

    private func configurePathMonitor(for state: _WhereWolfUploadSchedulerState) {
        if state.connectivityRetryEnabled {
            guard pathMonitor == nil else { return }
            let monitor = dependencies.makePathMonitor()
            pathMonitor = monitor
            pathHasValue = false
            pathSatisfied = false
            monitor.onPathUpdate = { [weak self] satisfied in
                Task { @MainActor in
                    self?.receivePathUpdate(satisfied)
                }
            }
            monitor.start()
        } else {
            pathMonitor?.cancel()
            pathMonitor = nil
            pathHasValue = false
            pathSatisfied = false
        }
    }

    private func receivePathUpdate(_ satisfied: Bool) {
        guard dependencies.state().connectivityRetryEnabled else { return }
        if !pathHasValue {
            pathHasValue = true
            pathSatisfied = satisfied
            return
        }
        let transitionedToSatisfied = !pathSatisfied && satisfied
        pathSatisfied = satisfied
        if transitionedToSatisfied {
            let state = dependencies.state()
            if state.pendingUploads && !state.uploadsBlocked {
                dependencies.resumeUploadAfterConnectivity()
            }
        }
        if activeTask != nil {
            evaluateActiveTask(allowResume: !transitionedToSatisfied)
        } else {
            reconcile()
        }
    }

    private func reconcile() {
        let state = dependencies.state()
        configurePathMonitor(for: state)
        guard registered else {
            statusValue = "Unavailable"
            return
        }
        if let activeTask {
            evaluateActiveTask(allowResume: false)
            updateStatus(for: state, active: activeTask)
            return
        }
        guard state.backgroundUploadsEnabled, state.pendingUploads, !state.uploadsBlocked else {
            cancelScheduledPlan()
            updateStatus(for: state, active: nil)
            return
        }
        let plan = SchedulePlan(retryDate: state.uploadRetryDate)
        if scheduledPlan != plan {
            cancelScheduledPlan()
            do {
                try dependencies.submit(dependencies.identifier(), earliestDate(for: plan))
                scheduledPlan = plan
                cancellationEnsured = false
            } catch {
                statusValue = "Unable to schedule"
                return
            }
        }
        updateStatus(for: state, active: nil)
    }

    private func earliestDate(for plan: SchedulePlan) -> Date {
        let minimum = dependencies.now().addingTimeInterval(60)
        guard let retryDate = plan.retryDate else { return minimum }
        return max(minimum, retryDate)
    }

    private func cancelScheduledPlan() {
        guard scheduledPlan != nil || !cancellationEnsured else { return }
        dependencies.cancel(dependencies.identifier())
        scheduledPlan = nil
        cancellationEnsured = true
    }

    private func updateStatus(for state: _WhereWolfUploadSchedulerState, active: _WhereWolfUploadSchedulerTask?) {
        guard started else {
            statusValue = "Not started"
            return
        }
        guard registered else {
            statusValue = "Unavailable"
            return
        }
        if active != nil {
            statusValue = "Running"
        } else if !state.backgroundUploadsEnabled {
            statusValue = "Off"
        } else if state.waitingForWifi {
            statusValue = "Waiting for Wi-Fi"
        } else if state.uploadsBlocked {
            statusValue = "Blocked"
        } else if !state.pendingUploads {
            statusValue = "Idle"
        } else if let retryDate = state.uploadRetryDate, retryDate > dependencies.now() {
            statusValue = "Waiting to retry"
        } else if scheduledPlan != nil {
            statusValue = "Scheduled"
        } else {
            statusValue = "Pending"
        }
    }

    private func handle(_ task: _WhereWolfUploadSchedulerTask) {
        guard activeTask == nil else {
            task.setTaskCompleted(success: false)
            return
        }
        scheduledPlan = nil
        cancellationEnsured = true
        activeTask = task
        task.expirationHandler = { [weak self, weak task] in
            guard let task else { return }
            Task { @MainActor in
                self?.expireActiveTask(task, success: false)
            }
        }
        activeDeadlineTask = Task { [weak self, weak task] in
            guard let self, let task else { return }
            do {
                try await self.dependencies.sleep(self.activeDeadline)
            } catch {
                return
            }
            self.expireActiveTask(task, success: false)
        }
        let state = dependencies.state()
        guard state.backgroundUploadsEnabled, state.pendingUploads, !state.uploadsBlocked else {
            finishActiveTask(task, success: true)
            return
        }
        dependencies.resumePendingUpload()
        evaluateActiveTask(allowResume: false)
    }

    private func evaluateActiveTask(allowResume: Bool) {
        guard let activeTask else { return }
        let state = dependencies.state()
        if !state.backgroundUploadsEnabled || !state.pendingUploads || state.uploadsBlocked {
            guard !state.sendInProgress else {
                updateStatus(for: state, active: activeTask)
                return
            }
            finishActiveTask(activeTask, success: true)
            return
        }
        if let retryDate = state.uploadRetryDate, retryDate > dependencies.now() {
            finishActiveTask(activeTask, success: true)
            return
        }
        if !state.sendInProgress, allowResume {
            dependencies.resumePendingUpload()
        }
        updateStatus(for: state, active: activeTask)
    }

    private func finishActiveTask(_ task: _WhereWolfUploadSchedulerTask, success: Bool) {
        guard activeTask === task else { return }
        activeTask = nil
        activeDeadlineTask?.cancel()
        activeDeadlineTask = nil
        task.expirationHandler = nil
        task.setTaskCompleted(success: success)
        reconcile()
    }

    private func expireActiveTask(_ task: _WhereWolfUploadSchedulerTask, success: Bool) {
        finishActiveTask(task, success: success)
    }

    internal func expireActiveTaskForTesting() {
        guard let activeTask else { return }
        expireActiveTask(activeTask, success: false)
    }

    internal func stopForTesting() {
        for token in observerTokens {
            dependencies.notificationCenter.removeObserver(token)
        }
        observerTokens.removeAll()
        pathMonitor?.cancel()
        pathMonitor = nil
        activeDeadlineTask?.cancel()
        activeDeadlineTask = nil
        if let activeTask {
            self.activeTask = nil
            activeTask.expirationHandler = nil
            activeTask.setTaskCompleted(success: false)
        }
        cancelScheduledPlan()
        started = false
        registered = false
        cancellationEnsured = false
        statusValue = "Not started"
    }
}
