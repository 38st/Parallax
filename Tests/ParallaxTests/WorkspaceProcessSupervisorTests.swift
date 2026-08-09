import Foundation
import XCTest
@testable import Parallax

final class WorkspaceProcessSupervisorTests: XCTestCase {
    func testExactNotificationEndsOnceAndWrongPIDIsOnlyIgnoredHint() {
        let fixture = SupervisorFixture()
        let ended = SupervisorLocked(0)
        let observation = fixture.supervisor.makeObservation(
            identity: fixture.identity
        ) { ended.mutate { $0 += 1 } }
        observation.start()

        observation.receiveTerminationHint(processIdentifier: 999)
        XCTAssertEqual(ended.value, 0)
        observation.receiveTerminationHint(
            processIdentifier: fixture.identity.processIdentifier
        )
        XCTAssertEqual(ended.value, 0)
        fixture.state.markExited(
            processIdentifier: fixture.identity.processIdentifier
        )
        observation.receiveTerminationHint(
            processIdentifier: fixture.identity.processIdentifier
        )
        observation.receiveTerminationHint(
            processIdentifier: fixture.identity.processIdentifier
        )

        XCTAssertEqual(ended.value, 1)
    }

    func testMissedNotificationPollDetectsExactDeath() {
        let fixture = SupervisorFixture()
        let ended = SupervisorLocked(0)
        let observation = fixture.supervisor.makeObservation(
            identity: fixture.identity
        ) { ended.mutate { $0 += 1 } }
        observation.start()
        fixture.state.markExited(
            processIdentifier: fixture.identity.processIdentifier
        )

        fixture.scheduler.runNext()

        XCTAssertEqual(ended.value, 1)
    }

    func testPIDReuseIncludingMicrosecondsProvesOldExactProcessEnded() {
        let fixture = SupervisorFixture()
        let ended = SupervisorLocked(0)
        let observation = fixture.supervisor.makeObservation(
            identity: fixture.identity
        ) { ended.mutate { $0 += 1 } }
        observation.start()
        let rebound = ProcessStartIdentity(
            processIdentifier: fixture.identity.processIdentifier,
            startTimeSeconds: fixture.identity.process.startTimeSeconds,
            startTimeMicroseconds:
                fixture.identity.process.startTimeMicroseconds + 1
        )
        fixture.state.processInspections[
            fixture.identity.processIdentifier
        ] = .live(rebound)

        fixture.scheduler.runNext()

        XCTAssertEqual(ended.value, 1)
    }

    func testInstallRaceIsClosedByImmediateVerification() {
        let fixture = SupervisorFixture()
        let ended = SupervisorLocked(0)
        let observation = fixture.supervisor.makeObservation(
            identity: fixture.identity
        ) { ended.mutate { $0 += 1 } }
        observation.installNotificationObservation(
            SupervisorNotificationObservation()
        )
        fixture.state.markExited(
            processIdentifier: fixture.identity.processIdentifier
        )

        observation.start()

        XCTAssertEqual(ended.value, 1)
        XCTAssertEqual(fixture.scheduler.pendingCount, 0)
    }

    func testAmbiguityRetainsAndRetriesUntilExactDeath() {
        let fixture = SupervisorFixture()
        let ended = SupervisorLocked(0)
        let observation = fixture.supervisor.makeObservation(
            identity: fixture.identity
        ) { ended.mutate { $0 += 1 } }
        fixture.state.returnedInspections[
            fixture.identity.processIdentifier
        ] = [.indeterminate, .indeterminate, .exited]

        observation.start()
        XCTAssertEqual(ended.value, 0)
        fixture.scheduler.runNext()
        XCTAssertEqual(ended.value, 0)
        fixture.scheduler.runNext()
        XCTAssertEqual(ended.value, 1)
    }

    func testCancelBeforeOrAfterTickSuppressesTerminalDelivery() {
        for cancelAfterFirstTick in [false, true] {
            let fixture = SupervisorFixture()
            let ended = SupervisorLocked(0)
            let observation = fixture.supervisor.makeObservation(
                identity: fixture.identity
            ) { ended.mutate { $0 += 1 } }
            observation.start()
            if cancelAfterFirstTick { fixture.scheduler.runNext() }
            observation.cancel()
            fixture.state.markExited(
                processIdentifier: fixture.identity.processIdentifier
            )
            fixture.scheduler.runAll()
            observation.receiveTerminationHint(
                processIdentifier: fixture.identity.processIdentifier
            )
            XCTAssertEqual(ended.value, 0)
        }
    }

    func testSynchronousSchedulerAndReentrantTaskCancellationDoNotDeadlock() {
        let state = TestWorkspaceProcessState()
        let scheduler = ReentrantSupervisorScheduler(
            synchronousFirings: 1
        )
        let application = WorkspaceApplicationBundleIdentity(
            bundleURL: URL(fileURLWithPath: "/Applications/Reentrant.app"),
            bundleIdentifier: "com.parallax.reentrant"
        )
        let identity = state.workspaceIdentity(
            processIdentifier: 12_002,
            application: application
        )
        let supervisor = WorkspaceProcessSupervisor(
            inspector: state,
            scheduler: scheduler,
            pollInterval: 1
        )
        let observation = supervisor.makeObservation(identity: identity) {}
        scheduler.onTaskCancel = { observation.wake() }

        observation.start()
        observation.wake()
        observation.cancel()

        XCTAssertGreaterThanOrEqual(scheduler.scheduleCount, 2)
    }

    func testRepeatedReentrantHintsDrainIterativelyWithoutStackGrowth() {
        let fixture = SupervisorFixture()
        let holder = SupervisorLocked<
            WorkspaceProcessSupervisionObservation?
        >(nil)
        let inspectionCount = SupervisorLocked(0)
        fixture.state.onReturnedInspection = { _, _ in
            let count = inspectionCount.mutate { count -> Int in
                count += 1
                return count
            }
            if count <= 2_000 { holder.value?.wake() }
        }
        let observation = fixture.supervisor.makeObservation(
            identity: fixture.identity
        ) {}
        holder.mutate { $0 = observation }

        observation.start()

        XCTAssertEqual(inspectionCount.value, 2_001)
        XCTAssertEqual(fixture.scheduler.pendingCount, 1)
        observation.cancel()
    }

    func testCancelPreventsCapturedCallbackFromStartingAfterReturn() {
        let fixture = SupervisorFixture()
        fixture.state.markExited(
            processIdentifier: fixture.identity.processIdentifier
        )
        let notification = BlockingSupervisorNotificationObservation()
        let ended = SupervisorLocked(0)
        let observation = fixture.supervisor.makeObservation(
            identity: fixture.identity
        ) { ended.mutate { $0 += 1 } }
        observation.installNotificationObservation(notification)
        let startReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            observation.start()
            startReturned.signal()
        }
        XCTAssertEqual(notification.cancelEntered.wait(timeout: .now() + 1), .success)

        observation.cancel()
        notification.allowCancelToReturn.signal()

        XCTAssertEqual(startReturned.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(ended.value, 0)
    }

    func testCancelWaitsForInFlightTerminalCallback() {
        let fixture = SupervisorFixture()
        fixture.state.markExited(
            processIdentifier: fixture.identity.processIdentifier
        )
        let callbackStarted = DispatchSemaphore(value: 0)
        let allowCallbackToReturn = DispatchSemaphore(value: 0)
        let cancelReturned = DispatchSemaphore(value: 0)
        let startReturned = DispatchSemaphore(value: 0)
        let observation = fixture.supervisor.makeObservation(
            identity: fixture.identity
        ) {
            callbackStarted.signal()
            allowCallbackToReturn.wait()
        }
        DispatchQueue.global().async {
            observation.start()
            startReturned.signal()
        }
        XCTAssertEqual(callbackStarted.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().async {
            observation.cancel()
            cancelReturned.signal()
        }

        XCTAssertEqual(
            cancelReturned.wait(timeout: .now() + 0.05),
            .timedOut
        )
        allowCallbackToReturn.signal()
        XCTAssertEqual(cancelReturned.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(startReturned.wait(timeout: .now() + 1), .success)
    }

    func testTerminalCallbackMayReentrantlyCancelItsOwnObservation() {
        let fixture = SupervisorFixture()
        fixture.state.markExited(
            processIdentifier: fixture.identity.processIdentifier
        )
        let holder = SupervisorLocked<
            WorkspaceProcessSupervisionObservation?
        >(nil)
        let ended = SupervisorLocked(0)
        let observation = fixture.supervisor.makeObservation(
            identity: fixture.identity
        ) {
            holder.value?.cancel()
            ended.mutate { $0 += 1 }
        }
        holder.mutate { $0 = observation }

        observation.start()

        XCTAssertEqual(ended.value, 1)
    }
}

private final class SupervisorFixture {
    let state = TestWorkspaceProcessState()
    let scheduler = SupervisorTestScheduler()
    let identity: WorkspaceProcessIdentity
    lazy var supervisor = WorkspaceProcessSupervisor(
        inspector: state,
        scheduler: scheduler,
        pollInterval: 1
    )

    init() {
        let application = WorkspaceApplicationBundleIdentity(
            bundleURL: URL(fileURLWithPath: "/Applications/Supervised.app"),
            bundleIdentifier: "com.parallax.supervised"
        )
        identity = state.workspaceIdentity(
            processIdentifier: 12_001,
            application: application
        )
    }
}

final class SupervisorTestScheduler:
    WorkspaceProcessSupervisionScheduling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var tasks: [SupervisorTestScheduledTask] = []

    var pendingCount: Int {
        lock.withLock { tasks.filter { !$0.isCancelled }.count }
    }

    func schedule(
        after interval: TimeInterval,
        _ action: @escaping @Sendable () -> Void
    ) -> any WorkspaceProcessSupervisionScheduledTask {
        let task = SupervisorTestScheduledTask(action: action)
        lock.withLock { tasks.append(task) }
        return task
    }

    func runNext() {
        let task: SupervisorTestScheduledTask? = lock.withLock {
            while !tasks.isEmpty {
                let candidate = tasks.removeFirst()
                if !candidate.isCancelled { return candidate }
            }
            return nil
        }
        task?.run()
    }

    func runAll() {
        while pendingCount > 0 { runNext() }
    }
}

private final class SupervisorTestScheduledTask:
    WorkspaceProcessSupervisionScheduledTask,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?

    init(action: @escaping @Sendable () -> Void) {
        self.action = action
    }

    var isCancelled: Bool { lock.withLock { action == nil } }

    func cancel() { lock.withLock { action = nil } }

    func run() {
        let action = lock.withLock {
            let action = self.action
            self.action = nil
            return action
        }
        action?()
    }
}

private final class ReentrantSupervisorScheduler:
    WorkspaceProcessSupervisionScheduling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var remainingSynchronousFirings: Int
    private var count = 0
    var onTaskCancel: (@Sendable () -> Void)?

    init(synchronousFirings: Int) {
        remainingSynchronousFirings = synchronousFirings
    }

    var scheduleCount: Int { lock.withLock { count } }

    func schedule(
        after interval: TimeInterval,
        _ action: @escaping @Sendable () -> Void
    ) -> any WorkspaceProcessSupervisionScheduledTask {
        let fireSynchronously = lock.withLock {
            count += 1
            guard remainingSynchronousFirings > 0 else { return false }
            remainingSynchronousFirings -= 1
            return true
        }
        if fireSynchronously { action() }
        return ReentrantSupervisorScheduledTask { [weak self] in
            self?.onTaskCancel?()
        }
    }
}

private final class ReentrantSupervisorScheduledTask:
    WorkspaceProcessSupervisionScheduledTask,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var onCancel: (@Sendable () -> Void)?

    init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        let callback = lock.withLock {
            let callback = onCancel
            onCancel = nil
            return callback
        }
        callback?()
    }
}

private final class SupervisorNotificationObservation:
    RunningApplicationTerminationObservation,
    @unchecked Sendable
{
    func cancel() {}
}

private final class BlockingSupervisorNotificationObservation:
    RunningApplicationTerminationObservation,
    @unchecked Sendable
{
    let cancelEntered = DispatchSemaphore(value: 0)
    let allowCancelToReturn = DispatchSemaphore(value: 0)

    func cancel() {
        cancelEntered.signal()
        allowCancelToReturn.wait()
    }
}

private final class SupervisorLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }
    var value: Value { lock.withLock { storage } }
    @discardableResult
    func mutate<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&storage) }
    }
}
