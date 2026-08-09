import Foundation

protocol WorkspaceProcessSupervisionScheduledTask: AnyObject, Sendable {
    func cancel()
}

protocol WorkspaceProcessSupervisionScheduling: Sendable {
    func schedule(
        after interval: TimeInterval,
        _ action: @escaping @Sendable () -> Void
    ) -> any WorkspaceProcessSupervisionScheduledTask
}

struct DispatchWorkspaceProcessSupervisionScheduler:
    WorkspaceProcessSupervisionScheduling,
    Sendable
{
    func schedule(
        after interval: TimeInterval,
        _ action: @escaping @Sendable () -> Void
    ) -> any WorkspaceProcessSupervisionScheduledTask {
        let item = DispatchWorkItem(block: action)
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + interval,
            execute: item
        )
        return DispatchWorkspaceProcessSupervisionTask(item: item)
    }
}

private final class DispatchWorkspaceProcessSupervisionTask:
    WorkspaceProcessSupervisionScheduledTask,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var item: DispatchWorkItem?

    init(item: DispatchWorkItem) {
        self.item = item
    }

    func cancel() {
        let item = lock.withLock {
            let item = self.item
            self.item = nil
            return item
        }
        item?.cancel()
    }

    deinit {
        cancel()
    }
}

/// Exact continuing supervision. Workspace termination notifications are only
/// wake-up hints; every terminal decision comes from a fresh full-identity
/// inspection and periodic polling remains authoritative when a notification
/// is missing.
final class WorkspaceProcessSupervisor: @unchecked Sendable {
    private let inspector: any WorkspaceLaunchProcessProvenanceInspecting
    private let scheduler: any WorkspaceProcessSupervisionScheduling
    private let pollInterval: TimeInterval

    init(
        inspector: any WorkspaceLaunchProcessProvenanceInspecting =
            WorkspaceProcessSnapshotter(),
        scheduler: any WorkspaceProcessSupervisionScheduling =
            DispatchWorkspaceProcessSupervisionScheduler(),
        pollInterval: TimeInterval = 1
    ) {
        self.inspector = inspector
        self.scheduler = scheduler
        self.pollInterval = pollInterval
    }

    func makeObservation(
        identity: WorkspaceProcessIdentity,
        onEnded: @escaping @Sendable () -> Void
    ) -> WorkspaceProcessSupervisionObservation {
        WorkspaceProcessSupervisionObservation(
            identity: identity,
            inspector: inspector,
            scheduler: scheduler,
            pollInterval: pollInterval,
            onEnded: onEnded
        )
    }
}

final class WorkspaceProcessSupervisionObservation:
    RunningApplicationTerminationObservation,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let identity: WorkspaceProcessIdentity
    private let inspector: any WorkspaceLaunchProcessProvenanceInspecting
    private let scheduler: any WorkspaceProcessSupervisionScheduling
    private let pollInterval: TimeInterval
    private var onEnded: (@Sendable () -> Void)?
    private var scheduledTask:
        (any WorkspaceProcessSupervisionScheduledTask)?
    private var scheduledGeneration: UInt64?
    private var schedulingGeneration: UInt64?
    private var nextScheduleGeneration: UInt64 = 0
    private var notificationObservation:
        (any RunningApplicationTerminationObservation)?
    private var started = false
    private var evaluating = false
    private var pendingWake = false
    private var terminal = false
    private let deliveryCondition = NSCondition()
    private var deliveryCancelled = false
    private var deliveryInFlight = false
    private var deliveryThreadID: ObjectIdentifier?

    fileprivate init(
        identity: WorkspaceProcessIdentity,
        inspector: any WorkspaceLaunchProcessProvenanceInspecting,
        scheduler: any WorkspaceProcessSupervisionScheduling,
        pollInterval: TimeInterval,
        onEnded: @escaping @Sendable () -> Void
    ) {
        self.identity = identity
        self.inspector = inspector
        self.scheduler = scheduler
        self.pollInterval = pollInterval
        self.onEnded = onEnded
    }

    func installNotificationObservation(
        _ observation: any RunningApplicationTerminationObservation
    ) {
        let cancel = lock.withLock {
            if terminal || notificationObservation != nil {
                return true
            }
            notificationObservation = observation
            return false
        }
        if cancel { observation.cancel() }
    }

    /// Must be called after notification observation installation. It performs
    /// the immediate verification that closes the install race.
    func start() {
        let shouldEvaluate = lock.withLock {
            guard !terminal, !started else { return false }
            started = true
            return true
        }
        if shouldEvaluate { evaluate() }
    }

    func receiveTerminationHint(processIdentifier: pid_t) {
        guard processIdentifier == identity.processIdentifier else { return }
        wake()
    }

    func wake() {
        let resources = lock.withLock { () -> (
            shouldEvaluate: Bool,
            task: (any WorkspaceProcessSupervisionScheduledTask)?
        ) in
            guard !terminal else { return (false, nil) }
            guard started else {
                pendingWake = true
                return (false, nil)
            }
            if evaluating || schedulingGeneration != nil {
                pendingWake = true
                return (false, nil)
            }
            evaluating = true
            pendingWake = false
            let task = scheduledTask
            scheduledTask = nil
            scheduledGeneration = nil
            return (true, task)
        }
        guard resources.shouldEvaluate else { return }
        resources.task?.cancel()
        drainEvaluations()
    }

    func cancel() {
        let resources = lock.withLock {
            guard !terminal else {
                return (
                    Optional<any WorkspaceProcessSupervisionScheduledTask>.none,
                    Optional<any RunningApplicationTerminationObservation>.none
                )
            }
            terminal = true
            onEnded = nil
            schedulingGeneration = nil
            scheduledGeneration = nil
            pendingWake = false
            let task = scheduledTask
            scheduledTask = nil
            let notification = notificationObservation
            notificationObservation = nil
            return (task, notification)
        }
        resources.0?.cancel()
        resources.1?.cancel()
        // This is a strong cancellation boundary: if terminal delivery was
        // already authorized, wait for it to finish; otherwise prevent it
        // from starting after this method returns.
        deliveryCondition.lock()
        deliveryCancelled = true
        let isReentrantDelivery = deliveryThreadID
            == ObjectIdentifier(Thread.current)
        while deliveryInFlight, !isReentrantDelivery {
            deliveryCondition.wait()
        }
        deliveryCondition.unlock()
    }

    private func evaluate() {
        let resources = lock.withLock {
            guard !terminal else {
                return (
                    false,
                    Optional<any WorkspaceProcessSupervisionScheduledTask>.none
                )
            }
            guard !evaluating, schedulingGeneration == nil else {
                pendingWake = true
                return (
                    false,
                    Optional<any WorkspaceProcessSupervisionScheduledTask>.none
                )
            }
            evaluating = true
            pendingWake = false
            let task = scheduledTask
            scheduledTask = nil
            scheduledGeneration = nil
            return (true, task)
        }
        guard resources.0 else { return }
        resources.1?.cancel()
        drainEvaluations()
    }

    private func drainEvaluations() {
        while true {
            let inspection = inspector.inspectReturnedProcess(
                processIdentifier: identity.processIdentifier,
                expectedApplication: identity.application
            )
            let ended: Bool
            switch inspection {
            case .exited:
                ended = true
            case .live(let current):
                ended = current.process != identity.process
            case .indeterminate:
                ended = false
            }

            var callback: (@Sendable () -> Void)?
            var notification:
                (any RunningApplicationTerminationObservation)?
            let next = lock.withLock { () -> EvaluationNextStep in
                guard !terminal else {
                    evaluating = false
                    return .stop
                }
                if ended {
                    terminal = true
                    evaluating = false
                    callback = onEnded
                    onEnded = nil
                    notification = notificationObservation
                    notificationObservation = nil
                    return .ended
                }
                if pendingWake {
                    pendingWake = false
                    return .inspectAgain
                }
                evaluating = false
                nextScheduleGeneration &+= 1
                let generation = nextScheduleGeneration
                schedulingGeneration = generation
                return .schedule(generation)
            }

            switch next {
            case .stop:
                return
            case .ended:
                notification?.cancel()
                deliver(callback)
                return
            case .inspectAgain:
                continue
            case .schedule(let generation):
                if installScheduledWake(generation: generation) {
                    continue
                }
                return
            }
        }
    }

    private func installScheduledWake(generation: UInt64) -> Bool {
        let task = scheduler.schedule(after: pollInterval) { [weak self] in
            self?.receiveScheduledWake(generation: generation)
        }
        let disposition = lock.withLock { () -> ScheduleDisposition in
            guard !terminal, schedulingGeneration == generation else {
                return .cancel
            }
            schedulingGeneration = nil
            if pendingWake {
                pendingWake = false
                evaluating = true
                return .cancelAndInspect
            }
            scheduledGeneration = generation
            scheduledTask = task
            return .installed
        }
        switch disposition {
        case .installed:
            return false
        case .cancel:
            task.cancel()
            return false
        case .cancelAndInspect:
            task.cancel()
            return true
        }
    }

    private func receiveScheduledWake(generation: UInt64) {
        let shouldEvaluate = lock.withLock {
            guard !terminal, started else { return false }
            if schedulingGeneration == generation {
                pendingWake = true
                return false
            }
            guard scheduledGeneration == generation else { return false }
            scheduledGeneration = nil
            scheduledTask = nil
            if evaluating {
                pendingWake = true
                return false
            }
            evaluating = true
            pendingWake = false
            return true
        }
        if shouldEvaluate { drainEvaluations() }
    }

    private func deliver(_ callback: (@Sendable () -> Void)?) {
        guard let callback else { return }
        deliveryCondition.lock()
        guard !deliveryCancelled else {
            deliveryCondition.unlock()
            return
        }
        deliveryInFlight = true
        deliveryThreadID = ObjectIdentifier(Thread.current)
        deliveryCondition.unlock()

        callback()

        deliveryCondition.lock()
        deliveryInFlight = false
        deliveryThreadID = nil
        deliveryCondition.broadcast()
        deliveryCondition.unlock()
    }

    deinit {
        cancel()
    }
}

private enum EvaluationNextStep {
    case stop
    case ended
    case inspectAgain
    case schedule(UInt64)
}

private enum ScheduleDisposition {
    case installed
    case cancel
    case cancelAndInspect
}
