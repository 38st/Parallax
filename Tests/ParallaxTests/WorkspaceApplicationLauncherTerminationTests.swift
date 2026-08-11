import AppKit
import Foundation
import XCTest
@testable import Parallax

private typealias ProvenanceTestOpener =
    ScriptedWorkspaceApplicationOpener
private typealias ProvenanceTestRunningApplication =
    ExactRunningApplicationHandle
private typealias ProvenanceTestTerminationObserver =
    TestRunningApplicationTerminationObserver
private typealias ProvenanceLocked<Value> = LaunchTestLocked<Value>

final class WorkspaceApplicationLauncherTerminationTests: XCTestCase {
    @MainActor
    func testDelayedActivationRefusesProcessIdentityRebind() {
        assertDelayedActivationRefusal(change: .processIdentity)
    }
    @MainActor
    func testDelayedActivationRefusesApplicationRebind() {
        assertDelayedActivationRefusal(change: .applicationIdentity)
    }
    @MainActor
    func testDelayedActivationRefusesUnavailableVerification() {
        assertDelayedActivationRefusal(change: .verificationUnavailable)
    }
    func testReturnedPIDMismatchRemainsBlockedUntilPIDIsProvenDead() throws {
        let harness = ProvenanceHarness()
        let prepared = Self.prepared()
        harness.state.returnedInspections[9104] = [
            .live(
                harness.state.workspaceIdentity(
                    processIdentifier: 9999,
                    application: prepared.applicationIdentity
                )
            )
        ]
        let launch = try harness.launcher.launchTracked(
            prepared: prepared,
            activityRegistry: harness.registry,
            eventHandler: { _ in }
        )
        let running = ProvenanceTestRunningApplication(processIdentifier: 9104)

        harness.opener.completeNext(.success(running))

        XCTAssertEqual(
            launch.processProvenance,
            .indeterminate(
                processIdentifier: 9104,
                reason: .processIdentifierMismatch
            )
        )
        XCTAssertEqual(launch.currentLifecycle.state, .launching)
        XCTAssertTrue(
            harness.registry.isActive(
                identity: Self.activityIdentity(for: prepared)
            )
        )
        XCTAssertEqual(running.activationCount, 0)

        harness.terminationObserver.terminate(running)
        guard case .failed = launch.currentLifecycle.state else {
            return XCTFail("An unverified process exit must remain a failed open.")
        }
        XCTAssertEqual(
            launch.currentLifecycle.openingDisposition,
            .provenanceIndeterminate(
                processIdentifier: 9104,
                reason: .exitedBeforeVerification
            )
        )
        XCTAssertNil(launch.currentLifecycle.processIdentity)
    }
    func testSameSecondDifferentMicrosecondBeforeRegistrationNeverRuns()
        throws
    {
        let harness = ProvenanceHarness()
        let prepared = Self.prepared()
        let admitted = harness.state.processIdentity(processIdentifier: 9105)
        harness.state.processInspections[9105] = .live(admitted)
        harness.state.onReturnedInspection = { count, processIdentifier in
            if count == 2 {
                harness.state.processInspections[processIdentifier] = .live(
                    ProcessStartIdentity(
                        processIdentifier: processIdentifier,
                        startTimeSeconds: admitted.startTimeSeconds,
                        startTimeMicroseconds:
                            admitted.startTimeMicroseconds + 1
                    )
                )
            }
        }
        let launch = try harness.launcher.launchTracked(
            prepared: prepared,
            activityRegistry: harness.registry,
            eventHandler: { _ in }
        )
        let running = ProvenanceTestRunningApplication(processIdentifier: 9105)

        harness.opener.completeNext(.success(running))

        XCTAssertFalse(launch.currentLifecycle.state.isRunningForTest)
        XCTAssertFalse(
            harness.registry.runningProcesses(
                applicationStorageID: prepared.applicationStorageID
            ).contains { $0.process == admitted }
        )
    }
    func testSameStartWithChangedBundleRetainsGateUntilExactExit() throws {
        let harness = ProvenanceHarness()
        let prepared = Self.prepared()
        let exact = harness.state.workspaceIdentity(
            processIdentifier: 9106,
            application: prepared.applicationIdentity
        )
        let changedBundle = WorkspaceProcessIdentity(
            process: exact.process,
            application: WorkspaceApplicationBundleIdentity(
                bundleURL: URL(fileURLWithPath: "/Applications/Changed.app"),
                bundleIdentifier: "com.parallax.changed"
            )
        )
        harness.state.returnedInspections[9106] = [
            .live(exact),
            .live(changedBundle),
        ]
        let launch = try harness.launcher.launchTracked(
            prepared: prepared,
            activityRegistry: harness.registry,
            eventHandler: { _ in }
        )
        let running = ProvenanceTestRunningApplication(processIdentifier: 9106)

        harness.opener.completeNext(.success(running))

        XCTAssertEqual(
            launch.processProvenance,
            .indeterminate(
                processIdentifier: 9106,
                reason: .unverifiableIdentity
            )
        )
        XCTAssertEqual(launch.currentLifecycle.state, .launching)
        XCTAssertTrue(
            harness.registry.isActive(
                identity: Self.activityIdentity(for: prepared)
            )
        )
        XCTAssertEqual(running.activationCount, 0)

        harness.terminationObserver.terminate(running)
        XCTAssertFalse(
            harness.registry.isActive(
                identity: Self.activityIdentity(for: prepared)
            )
        )
    }
    func testFinalPostRecordStartChangeNeverPublishesRunning() throws {
        try assertFinalPostRecordChangeNeverRuns(change: .startIdentity)
    }
    func testFinalPostRecordBundleChangeNeverPublishesRunning() throws {
        try assertFinalPostRecordChangeNeverRuns(change: .bundleIdentity)
    }
    func testCompetingFinishDoesNotCancelObservationUnderDeliveryLock()
        throws
    {
        let prepared = Self.prepared()
        let state = TestWorkspaceProcessState()
        let registry = ProfileActivityRegistry(processInspector: state)
        let identity = Self.activityIdentity(for: prepared)
        let lease = try registry.acquireLaunchLease(
            identity: identity,
            requestID: prepared.requestID
        )
        let events = ProvenanceLocked<[TrackedApplicationLaunchEvent]>([])
        let lifecycles = ProvenanceLocked<[ProfileLaunchLifecycleSnapshot]>([])
        let launch = TrackedApplicationLaunch(
            requestID: prepared.requestID,
            identity: identity,
            activityRegistry: registry,
            activityLease: lease,
            expectedApplication: prepared.applicationIdentity,
            processProvenanceInspector: state,
            processSupervisor: WorkspaceProcessSupervisor(
                inspector: state,
                scheduler: SupervisorTestScheduler(),
                pollInterval: 1
            ),
            launchAuthority: WorkspaceApplicationLaunchAuthority(),
            lifecycleHandler: { lifecycle in
                lifecycles.mutate { $0.append(lifecycle) }
            },
            eventHandler: { event in events.mutate { $0.append(event) } }
        )
        let observation = JoiningTerminationObservation()
        observation.callback = {
            // Models an in-flight supervisor callback that must enter the same
            // delivery serialization boundary while competing finish cleanup
            // strongly cancels and joins the observation.
            launch.didFail(ProvenanceFixtureError.openFailed)
        }
        launch.install(observation)
        let finishReturned = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            launch.didFail(ProvenanceFixtureError.openFailed)
            finishReturned.signal()
        }

        XCTAssertEqual(finishReturned.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(observation.callbackCompletedBeforeCancelReturned)
        XCTAssertEqual(events.value.count, 1)
        XCTAssertEqual(lifecycles.value.count, 1)
        XCTAssertFalse(registry.isActive(identity: identity))
    }

    func testTerminationReleasesResourcesBeforeLifecycleAndEventCallbacks()
        throws
    {
        let harness = ProvenanceHarness()
        let prepared = Self.prepared()
        let activityIdentity = Self.activityIdentity(for: prepared)
        let processIdentifier: pid_t = 9_121
        let exact = harness.state.workspaceIdentity(
            processIdentifier: processIdentifier,
            application: prepared.applicationIdentity
        )
        let callbacks = LaunchTestRecorder<TerminalCallbackSnapshot>()
        let registry = harness.registry
        let observer = harness.terminationObserver
        let authority = harness.authority
        let launch = try harness.launcher.launchTracked(
            prepared: prepared,
            activityRegistry: registry,
            lifecycleHandler: { lifecycle in
                guard case .terminated = lifecycle.state else { return }
                callbacks.append(
                    TerminalCallbackSnapshot(
                        kind: .lifecycle,
                        activityIsActive:
                            registry.isActive(identity: activityIdentity),
                        observationCount: observer.observationCount,
                        authorityIsClaimed: authority.isClaimed(
                            exact,
                            requestID: prepared.requestID
                        )
                    )
                )
            },
            eventHandler: { event in
                guard case .terminated = event else { return }
                callbacks.append(
                    TerminalCallbackSnapshot(
                        kind: .event,
                        activityIsActive:
                            registry.isActive(identity: activityIdentity),
                        observationCount: observer.observationCount,
                        authorityIsClaimed: authority.isClaimed(
                            exact,
                            requestID: prepared.requestID
                        )
                    )
                )
            }
        )
        let running = ProvenanceTestRunningApplication(
            processIdentifier: processIdentifier
        )
        harness.opener.completeNext(.success(running))

        XCTAssertEqual(
            launch.currentLifecycle.state,
            .running(processIdentifier: processIdentifier)
        )
        XCTAssertTrue(registry.isActive(identity: activityIdentity))
        XCTAssertEqual(observer.observationCount, 1)
        XCTAssertTrue(
            authority.isClaimed(exact, requestID: prepared.requestID)
        )

        observer.terminate(running)

        XCTAssertEqual(
            callbacks.values,
            [
                TerminalCallbackSnapshot(
                    kind: .lifecycle,
                    activityIsActive: false,
                    observationCount: 0,
                    authorityIsClaimed: false
                ),
                TerminalCallbackSnapshot(
                    kind: .event,
                    activityIsActive: false,
                    observationCount: 0,
                    authorityIsClaimed: false
                ),
            ]
        )
        XCTAssertEqual(observer.lastObservation?.isCancelled, true)
    }
    private static func prepared() -> PreparedLaunch {
        PreparedLaunch(
            requestID: UUID(),
            applicationID: UUID(),
            applicationStorageID: UUID(),
            profileID: UUID(),
            profileStorageID: UUID(),
            applicationIdentity: WorkspaceApplicationBundleIdentity(
                bundleURL: URL(fileURLWithPath: "/Applications/Provenance Test.app"),
                bundleIdentifier: "com.parallax.provenance-test"
            ),
            arguments: ["--profile", "isolated"],
            environment: ["PARALLAX_TEST": "1"],
            isolation: PreparedLaunchIsolation(
                userDataURL: nil,
                codexHomeURL: nil,
                managesUserData: false,
                managesCodexHome: false
            ),
            configurationFingerprint: LaunchConfigurationFingerprint(
                digest: "provenance-test"
            )
        )
    }
    private static func activityIdentity(
        for prepared: PreparedLaunch
    ) -> ProfileActivityIdentity {
        ProfileActivityIdentity(
            applicationID: prepared.applicationID,
            applicationStorageID: prepared.applicationStorageID,
            profileID: prepared.profileID,
            profileStorageID: prepared.profileStorageID
        )
    }
    private enum FinalIdentityChange {
        case startIdentity
        case bundleIdentity
    }
    private enum DelayedActivationChange {
        case processIdentity
        case applicationIdentity
        case verificationUnavailable
    }
    @MainActor
    private func assertDelayedActivationRefusal(
        change: DelayedActivationChange
    ) {
        let state = TestWorkspaceProcessState()
        let prepared = Self.prepared()
        let exact = state.workspaceIdentity(
            processIdentifier: 9_114,
            application: prepared.applicationIdentity
        )
        state.processInspections[9_114] = .live(exact.process)
        let handle = DelayedActivationHandle(identity: exact)
        let runtime = DelayedActivationRuntime(handle: handle)
        let provider = NSWorkspaceApplicationProcessProvider(
            processInspector: state,
            runtime: runtime
        )
        let scheduler = DeferredMainActorOperationScheduler()
        let requester = WorkspaceVerifiedActivationRequester(
            operation: { identity in
                _ = provider.requestActivation(of: identity)
            },
            schedule: scheduler.enqueue
        )

        requester.requestActivation(of: exact)
        switch change {
        case .processIdentity:
            state.processInspections[9_114] = .live(
                ProcessStartIdentity(
                    processIdentifier: 9_114,
                    startTimeSeconds: exact.process.startTimeSeconds + 1,
                    startTimeMicroseconds: exact.process.startTimeMicroseconds
                )
            )
        case .applicationIdentity:
            handle.bundleURL = URL(fileURLWithPath: "/Applications/Rebound.app")
            handle.bundleIdentifier = "com.parallax.rebound"
        case .verificationUnavailable:
            state.processInspections[9_114] = .ambiguous
        }

        scheduler.runNext()

        XCTAssertEqual(runtime.yieldCount, 0)
        XCTAssertEqual(handle.coordinatedActivationCount, 0)
        XCTAssertEqual(handle.fallbackActivationCount, 0)
    }
    private func assertFinalPostRecordChangeNeverRuns(
        change: FinalIdentityChange,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let harness = ProvenanceHarness()
        let prepared = Self.prepared()
        let pid: pid_t
        switch change {
        case .startIdentity:
            pid = 9111
        case .bundleIdentity:
            pid = 9112
        }
        let exact = harness.state.workspaceIdentity(
            processIdentifier: pid,
            application: prepared.applicationIdentity
        )
        let changed: WorkspaceProcessIdentity
        switch change {
        case .startIdentity:
            changed = WorkspaceProcessIdentity(
                process: ProcessStartIdentity(
                    processIdentifier: pid,
                    startTimeSeconds: exact.process.startTimeSeconds,
                    startTimeMicroseconds:
                        exact.process.startTimeMicroseconds + 1
                ),
                application: exact.application
            )
        case .bundleIdentity:
            changed = WorkspaceProcessIdentity(
                process: exact.process,
                application: WorkspaceApplicationBundleIdentity(
                    bundleURL: URL(
                        fileURLWithPath: "/Applications/Final Changed.app"
                    ),
                    bundleIdentifier: "com.parallax.final-changed"
                )
            )
        }
        harness.state.returnedInspections[pid] = [
            .live(exact),
            .live(exact),
            .live(changed),
        ]
        let events = ProvenanceLocked<[TrackedApplicationLaunchEvent]>([])
        let launch = try harness.launcher.launchTracked(
            prepared: prepared,
            activityRegistry: harness.registry,
            eventHandler: { event in events.mutate { $0.append(event) } }
        )
        let running = ProvenanceTestRunningApplication(processIdentifier: pid)

        harness.opener.completeNext(.success(running))

        XCTAssertEqual(launch.currentLifecycle.state, .launching, file: file, line: line)
        XCTAssertFalse(events.value.contains { event in
            if case .running = event { return true }
            return false
        }, file: file, line: line)
        XCTAssertTrue(
            harness.registry.isActive(
                identity: Self.activityIdentity(for: prepared)
            ),
            file: file,
            line: line
        )
    }
}

private final class JoiningTerminationObservation:
    RunningApplicationTerminationObservation,
    @unchecked Sendable
{
    private let lock = NSLock()
    var callback: (@Sendable () -> Void)?
    private(set) var callbackCompletedBeforeCancelReturned = false
    private var cancelled = false

    func cancel() {
        let callback = lock.withLock {
            guard !cancelled else {
                return Optional<@Sendable () -> Void>.none
            }
            cancelled = true
            return self.callback
        }
        guard let callback else { return }
        let callbackReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            callback()
            callbackReturned.signal()
        }
        let completed = callbackReturned.wait(timeout: .now() + 1)
            == .success
        lock.withLock {
            callbackCompletedBeforeCancelReturned = completed
        }
    }
}

private enum TerminalCallbackKind: Equatable {
    case lifecycle
    case event
}

private struct TerminalCallbackSnapshot: Equatable {
    let kind: TerminalCallbackKind
    let activityIsActive: Bool
    let observationCount: Int
    let authorityIsClaimed: Bool
}

private final class DeferredMainActorOperationScheduler:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var operations: [@MainActor @Sendable () -> Void] = []

    func enqueue(
        _ operation: @escaping @MainActor @Sendable () -> Void
    ) {
        lock.withLock { operations.append(operation) }
    }

    @MainActor
    func runNext() {
        let operation = lock.withLock { operations.removeFirst() }
        operation()
    }
}

private final class DelayedActivationRuntime:
    WorkspaceApplicationProcessRuntime
{
    let handle: DelayedActivationHandle
    private(set) var yieldCount = 0

    init(handle: DelayedActivationHandle) {
        self.handle = handle
    }

    func runningApplications() -> [any WorkspaceApplicationOperationHandle] {
        [handle]
    }

    func yieldActivation(
        to application: any WorkspaceApplicationOperationHandle
    ) {
        yieldCount += 1
    }
}

private final class DelayedActivationHandle:
    WorkspaceApplicationOperationHandle
{
    let processIdentifier: pid_t
    var bundleURL: URL?
    var bundleIdentifier: String?
    var isTerminated = false
    private(set) var coordinatedActivationCount = 0
    private(set) var fallbackActivationCount = 0

    init(identity: WorkspaceProcessIdentity) {
        processIdentifier = identity.processIdentifier
        bundleURL = identity.application.bundleURL
        bundleIdentifier = identity.application.bundleIdentifier
    }

    func requestTermination() -> Bool { true }

    func requestCoordinatedActivation() -> Bool {
        coordinatedActivationCount += 1
        return true
    }

    func requestFallbackActivation() -> Bool {
        fallbackActivationCount += 1
        return true
    }
}
