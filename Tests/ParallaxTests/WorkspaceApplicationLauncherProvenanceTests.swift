import AppKit
import Foundation
import XCTest
@testable import Parallax

final class WorkspaceApplicationLauncherProvenanceTests: XCTestCase {
    func testPreopenFailureRollsBackRequestGateWithoutCallingOpener() throws {
        let state = TestWorkspaceProcessState()
        state.snapshotError = .processListUnavailable
        let opener = ProvenanceTestOpener()
        let launcher = WorkspaceApplicationLauncher(
            opener: opener,
            terminationObserver: ProvenanceTestTerminationObserver(state: state),
            processProvenanceInspector: state,
            launchRequestTimeProvider: ProvenanceTestTimeProvider()
        )
        let registry = ProfileActivityRegistry(processInspector: state)
        let prepared = Self.prepared()
        let identity = Self.activityIdentity(for: prepared)

        XCTAssertThrowsError(
            try launcher.launchTracked(
                prepared: prepared,
                activityRegistry: registry,
                eventHandler: { _ in }
            )
        ) { error in
            guard case LaunchError.launchProcessProvenanceUnavailable = error
            else {
                return XCTFail("Expected fail-closed pre-open snapshot error.")
            }
        }
        XCTAssertEqual(opener.openCount, 0)
        XCTAssertFalse(registry.isActive(identity: identity))
    }

    func testSnapshotRunsAfterRequestGateAndSeesProcessThatAppearedDuringSetup()
        throws
    {
        let state = TestWorkspaceProcessState()
        let opener = ProvenanceTestOpener()
        let observer = ProvenanceTestTerminationObserver(state: state)
        let launcher = WorkspaceApplicationLauncher(
            opener: opener,
            terminationObserver: observer,
            processProvenanceInspector: state,
            launchRequestTimeProvider: ProvenanceTestTimeProvider()
        )
        let registry = ProfileActivityRegistry(processInspector: state)
        let prepared = Self.prepared()
        let activityIdentity = Self.activityIdentity(for: prepared)
        let exact = state.workspaceIdentity(
            processIdentifier: 9110,
            application: prepared.applicationIdentity
        )
        state.onSnapshot = {
            XCTAssertTrue(registry.isActive(identity: activityIdentity))
            state.preexistingProcesses = [exact]
        }
        let launch = try launcher.launchTracked(
            prepared: prepared,
            activityRegistry: registry,
            eventHandler: { _ in }
        )
        let running = ProvenanceTestRunningApplication(processIdentifier: 9110)

        opener.completeNext(.success(running))

        XCTAssertEqual(launch.processProvenance, .preExisting(exact))
        XCTAssertEqual(launch.currentLifecycle.state, .launching)
        XCTAssertTrue(registry.isActive(identity: activityIdentity))
    }

    func testSynchronousOpenerFailureRetainsUnknownOutcomeReceipt() throws {
        let state = TestWorkspaceProcessState()
        let opener = ProvenanceTestOpener()
        opener.synchronousResult = .failure(
            ProvenanceFixtureError.openFailed
        )
        let launcher = WorkspaceApplicationLauncher(
            opener: opener,
            terminationObserver: ProvenanceTestTerminationObserver(state: state),
            processProvenanceInspector: state,
            launchRequestTimeProvider: ProvenanceTestTimeProvider()
        )
        let registry = ProfileActivityRegistry(processInspector: state)
        let prepared = Self.prepared()
        let events = ProvenanceLocked<[TrackedApplicationLaunchEvent]>([])

        let launch = try launcher.launchTracked(
            prepared: prepared,
            activityRegistry: registry,
            eventHandler: { event in events.mutate { $0.append(event) } }
        )

        XCTAssertEqual(launch.currentLifecycle.state, .launching)
        XCTAssertEqual(
            launch.currentLifecycle.openingDisposition,
            .outcomeUnknownAfterError(message: "open failed")
        )
        XCTAssertEqual(
            events.value,
            [
                .requested(requestID: prepared.requestID),
                .failed(
                    requestID: prepared.requestID,
                    message: "open failed"
                ),
            ]
        )
        XCTAssertTrue(
            registry.isActive(identity: Self.activityIdentity(for: prepared))
        )
    }

    func testUnknownOutcomeStallsQueueAcrossEveryUnprovenProcessState()
        throws
    {
        for scenario in UnknownOutcomeScenario.allCases {
            let state = TestWorkspaceProcessState()
            let authority = WorkspaceApplicationLaunchAuthority()
            let firstOpener = ProvenanceTestOpener()
            let secondOpener = ProvenanceTestOpener()
            let firstLauncher = WorkspaceApplicationLauncher(
                opener: firstOpener,
                terminationObserver:
                    ProvenanceTestTerminationObserver(state: state),
                processProvenanceInspector: state,
                launchRequestTimeProvider: ProvenanceTestTimeProvider(),
                launchAuthority: authority
            )
            let secondLauncher = WorkspaceApplicationLauncher(
                opener: secondOpener,
                terminationObserver:
                    ProvenanceTestTerminationObserver(state: state),
                processProvenanceInspector: state,
                launchRequestTimeProvider: ProvenanceTestTimeProvider(),
                launchAuthority: authority
            )
            let firstPrepared = Self.prepared()
            let secondPrepared = Self.prepared()
            let baseline = state.workspaceIdentity(
                processIdentifier: 9_114,
                application: firstPrepared.applicationIdentity
            )
            if scenario == .preexistingBaseline {
                state.preexistingProcesses = [baseline]
            }
            let firstRegistry = ProfileActivityRegistry(
                processInspector: state
            )
            let secondRegistry = ProfileActivityRegistry(
                processInspector: state
            )
            let first = try firstLauncher.launchTracked(
                prepared: firstPrepared,
                activityRegistry: firstRegistry,
                eventHandler: { _ in }
            )
            _ = try secondLauncher.launchTracked(
                prepared: secondPrepared,
                activityRegistry: secondRegistry,
                eventHandler: { _ in }
            )

            XCTAssertEqual(firstOpener.openCount, 1, "\(scenario)")
            XCTAssertEqual(secondOpener.openCount, 0, "\(scenario)")
            firstOpener.completeNext(
                .failure(ProvenanceFixtureError.openFailed)
            )

            if scenario == .delayedNewProcess {
                let delayed = state.workspaceIdentity(
                    processIdentifier: 9_115,
                    application: firstPrepared.applicationIdentity
                )
                state.preexistingProcesses = [delayed]
                XCTAssertEqual(secondOpener.openCount, 0, "delayed live")
                state.markExited(
                    processIdentifier: delayed.processIdentifier
                )
                state.preexistingProcesses = []
            } else if scenario == .preexistingBaseline {
                state.markExited(
                    processIdentifier: baseline.processIdentifier
                )
                state.preexistingProcesses = []
            }

            XCTAssertEqual(first.currentLifecycle.state, .launching)
            XCTAssertTrue(
                firstRegistry.isActive(
                    identity: Self.activityIdentity(for: firstPrepared)
                )
            )
            XCTAssertEqual(
                secondOpener.openCount,
                0,
                "PROV-002 must not authorize recovery for \(scenario)"
            )
        }
    }

    func testLateSuccessAfterUnknownOpenOutcomeHasNoRetryAuthority() throws {
        let harness = ProvenanceHarness()
        let prepared = Self.prepared()
        let events = ProvenanceLocked<[TrackedApplicationLaunchEvent]>([])
        let launch = try harness.launcher.launchTracked(
            prepared: prepared,
            activityRegistry: harness.registry,
            eventHandler: { event in events.mutate { $0.append(event) } }
        )

        harness.opener.completeNext(
            .failure(ProvenanceFixtureError.openFailed)
        )
        harness.opener.replayLast(
            .success(
                ProvenanceTestRunningApplication(processIdentifier: 9113)
            )
        )

        XCTAssertEqual(launch.currentLifecycle.state, .launching)
        XCTAssertEqual(
            launch.currentLifecycle.openingDisposition,
            .outcomeUnknownAfterError(message: "open failed")
        )
        XCTAssertFalse(events.value.contains { event in
            if case .running = event { return true }
            return false
        })
        XCTAssertTrue(
            harness.registry.isActive(
                identity: Self.activityIdentity(for: prepared)
            )
        )
    }

    func testExactNewProcessIsPublishedWithIdentityAndActivationDisabled()
        throws
    {
        let harness = ProvenanceHarness()
        let prepared = Self.prepared()
        let lifecycles = ProvenanceLocked<[ProfileLaunchLifecycleSnapshot]>([])
        let launch = try harness.launcher.launchTracked(
            prepared: prepared,
            activityRegistry: harness.registry,
            lifecycleHandler: { snapshot in
                lifecycles.mutate { $0.append(snapshot) }
            },
            eventHandler: { _ in }
        )
        let running = ProvenanceTestRunningApplication(processIdentifier: 9101)

        harness.opener.completeNext(.success(running))

        let exact = harness.state.workspaceIdentity(
            processIdentifier: running.processIdentifier,
            application: prepared.applicationIdentity
        )
        XCTAssertEqual(launch.processProvenance, .new(exact))
        XCTAssertEqual(launch.currentLifecycle.processIdentity, exact)
        XCTAssertEqual(launch.currentLifecycle.state, .running(processIdentifier: 9101))
        XCTAssertEqual(lifecycles.value.last?.processIdentity, exact)
        XCTAssertEqual(harness.opener.lastActivates, false)
        XCTAssertTrue(harness.authority.isClaimed(exact, requestID: prepared.requestID))
    }

    func testSuccessThenFailureReplayCannotMutateAdmittedLaunch() throws {
        let harness = ProvenanceHarness()
        let prepared = Self.prepared()
        let events = ProvenanceLocked<[TrackedApplicationLaunchEvent]>([])
        let launch = try harness.launcher.launchTracked(
            prepared: prepared,
            activityRegistry: harness.registry,
            eventHandler: { event in events.mutate { $0.append(event) } }
        )
        let running = ProvenanceTestRunningApplication(
            processIdentifier: 9_117
        )

        harness.opener.completeNext(.success(running))
        harness.opener.replayLast(
            .failure(ProvenanceFixtureError.openFailed)
        )

        XCTAssertEqual(
            launch.currentLifecycle.state,
            .running(processIdentifier: running.processIdentifier)
        )
        XCTAssertEqual(launch.currentLifecycle.openingDisposition, .pending)
        XCTAssertEqual(
            events.value,
            [
                .requested(requestID: prepared.requestID),
                .running(
                    requestID: prepared.requestID,
                    processIdentifier: running.processIdentifier
                ),
            ]
        )
        harness.terminationObserver.terminate(running)
    }

    func testSuccessThenSuccessReplayCannotReplaceProcessOrObserver() throws {
        let harness = ProvenanceHarness()
        let prepared = Self.prepared()
        let events = ProvenanceLocked<[TrackedApplicationLaunchEvent]>([])
        let launch = try harness.launcher.launchTracked(
            prepared: prepared,
            activityRegistry: harness.registry,
            eventHandler: { event in events.mutate { $0.append(event) } }
        )
        let admitted = ProvenanceTestRunningApplication(
            processIdentifier: 9_118
        )
        let replayed = ProvenanceTestRunningApplication(
            processIdentifier: 9_119
        )

        harness.opener.completeNext(.success(admitted))
        let exact = harness.state.workspaceIdentity(
            processIdentifier: admitted.processIdentifier,
            application: prepared.applicationIdentity
        )
        harness.opener.replayLast(.success(replayed))
        harness.terminationObserver.terminate(replayed)

        XCTAssertEqual(launch.processProvenance, .new(exact))
        XCTAssertEqual(
            launch.currentLifecycle.state,
            .running(processIdentifier: admitted.processIdentifier)
        )
        XCTAssertEqual(
            events.value.filter { event in
                if case .running = event { return true }
                return false
            }.count,
            1
        )
        harness.terminationObserver.terminate(admitted)
    }

    func testPreExistingProcessNeverPublishesRunningAndRetainsGateUntilExit()
        throws
    {
        let harness = ProvenanceHarness()
        let prepared = Self.prepared()
        let exact = harness.state.workspaceIdentity(
            processIdentifier: 9102,
            application: prepared.applicationIdentity
        )
        harness.state.preexistingProcesses = [exact]
        let events = ProvenanceLocked<[TrackedApplicationLaunchEvent]>([])
        let launch = try harness.launcher.launchTracked(
            prepared: prepared,
            activityRegistry: harness.registry,
            eventHandler: { event in events.mutate { $0.append(event) } }
        )
        let running = ProvenanceTestRunningApplication(processIdentifier: 9102)

        harness.opener.completeNext(.success(running))

        XCTAssertEqual(launch.processProvenance, .preExisting(exact))
        XCTAssertEqual(launch.currentLifecycle.state, .launching)
        XCTAssertFalse(events.value.contains { event in
            if case .running = event { return true }
            return false
        })
        XCTAssertTrue(
            harness.registry.isActive(
                identity: Self.activityIdentity(for: prepared)
            )
        )

        harness.terminationObserver.terminate(running)

        XCTAssertEqual(
            launch.currentLifecycle.state,
            .terminated(processIdentifier: 9102)
        )
        XCTAssertFalse(
            harness.registry.isActive(
                identity: Self.activityIdentity(for: prepared)
            )
        )
    }

    func testSameApplicationSubmissionsAreCausallySerialized() throws {
        let state = TestWorkspaceProcessState()
        let authority = WorkspaceApplicationLaunchAuthority()
        let firstOpener = ProvenanceTestOpener()
        let secondOpener = ProvenanceTestOpener()
        let firstObserver = ProvenanceTestTerminationObserver(state: state)
        let secondObserver = ProvenanceTestTerminationObserver(state: state)
        let firstLauncher = WorkspaceApplicationLauncher(
            opener: firstOpener,
            terminationObserver: firstObserver,
            processProvenanceInspector: state,
            launchRequestTimeProvider: ProvenanceTestTimeProvider(),
            launchAuthority: authority
        )
        let secondLauncher = WorkspaceApplicationLauncher(
            opener: secondOpener,
            terminationObserver: secondObserver,
            processProvenanceInspector: state,
            launchRequestTimeProvider: ProvenanceTestTimeProvider(),
            launchAuthority: authority
        )
        let firstPrepared = Self.prepared()
        let secondPrepared = Self.prepared()
        let firstRegistry = ProfileActivityRegistry(processInspector: state)
        let secondRegistry = ProfileActivityRegistry(processInspector: state)
        let firstEvents = ProvenanceLocked<[TrackedApplicationLaunchEvent]>([])
        let secondEvents = ProvenanceLocked<[TrackedApplicationLaunchEvent]>([])
        let first = try firstLauncher.launchTracked(
            prepared: firstPrepared,
            activityRegistry: firstRegistry,
            eventHandler: { event in firstEvents.mutate { $0.append(event) } }
        )
        let second = try secondLauncher.launchTracked(
            prepared: secondPrepared,
            activityRegistry: secondRegistry,
            eventHandler: { event in secondEvents.mutate { $0.append(event) } }
        )
        let singleton = ProvenanceTestRunningApplication(processIdentifier: 9103)
        let exact = state.workspaceIdentity(
            processIdentifier: singleton.processIdentifier,
            application: firstPrepared.applicationIdentity
        )
        state.onReturnedInspection = { count, _ in
            if count == 1 {
                state.preexistingProcesses = [exact]
            }
        }

        XCTAssertEqual(firstOpener.openCount, 1)
        XCTAssertEqual(secondOpener.openCount, 0)

        firstOpener.completeNext(.success(singleton))
        XCTAssertEqual(secondOpener.openCount, 1)
        secondOpener.completeNext(.success(singleton))

        guard case .new = first.processProvenance else {
            return XCTFail("The first exact claim should own the process.")
        }
        guard case .preExisting = second.processProvenance else {
            return XCTFail("The second fresh snapshot must see preexisting A.")
        }
        XCTAssertEqual(first.currentLifecycle.state, .running(processIdentifier: 9103))
        XCTAssertEqual(second.currentLifecycle.state, .launching)
        XCTAssertEqual(
            [firstEvents.value, secondEvents.value].filter { events in
                events.contains { event in
                    if case .running = event { return true }
                    return false
                }
            }.count,
            1
        )
    }

    func testTemporalBoundaryBeforeOrEqualStaysGatedAndAfterMayRun()
        throws
    {
        for (offset, shouldRun) in [(-1, false), (0, false), (1, true)] {
            let timeProvider = ProvenanceTestTimeProvider(
                seconds: 500,
                microseconds: 100
            )
            let harness = ProvenanceHarness(timeProvider: timeProvider)
            let prepared = Self.prepared()
            let pid = pid_t(9_200 + offset)
            let process = ProcessStartIdentity(
                processIdentifier: pid,
                startTimeSeconds: 500,
                startTimeMicroseconds: UInt64(100 + offset)
            )
            let exact = WorkspaceProcessIdentity(
                process: process,
                application: prepared.applicationIdentity
            )
            harness.state.processInspections[pid] = .live(process)
            harness.state.returnedInspections[pid] = [
                .live(exact), .live(exact), .live(exact),
            ]

            let launch = try harness.launcher.launchTracked(
                prepared: prepared,
                activityRegistry: harness.registry,
                eventHandler: { _ in }
            )
            harness.opener.completeNext(
                .success(
                    ProvenanceTestRunningApplication(processIdentifier: pid)
                )
            )

            XCTAssertEqual(
                launch.currentLifecycle.state.isRunningForTest,
                shouldRun,
                "offset \(offset)"
            )
            if shouldRun {
                XCTAssertEqual(launch.processProvenance, .new(exact))
            } else {
                XCTAssertEqual(
                    launch.processProvenance,
                    .indeterminate(
                        processIdentifier: pid,
                        reason: .processDidNotStartAfterLaunchBoundary
                    )
                )
                XCTAssertTrue(
                    harness.registry.isActive(
                        identity: Self.activityIdentity(for: prepared)
                    )
                )
            }
        }
    }

    func testBoundaryProviderFailureRefusesBeforeOpener() throws {
        let timeProvider = ProvenanceTestTimeProvider()
        timeProvider.failure = .unavailable
        let harness = ProvenanceHarness(timeProvider: timeProvider)
        let prepared = Self.prepared()

        XCTAssertThrowsError(
            try harness.launcher.launchTracked(
                prepared: prepared,
                activityRegistry: harness.registry,
                eventHandler: { _ in }
            )
        ) { error in
            guard case LaunchError.launchTimeBoundaryUnavailable = error else {
                return XCTFail("Expected fail-closed boundary error.")
            }
        }
        XCTAssertEqual(harness.opener.openCount, 0)
        XCTAssertFalse(
            harness.registry.isActive(
                identity: Self.activityIdentity(for: prepared)
            )
        )
    }

    func testSnapshotAndBoundaryOccurAfterMarkerImmediatelyBeforeOpen()
        throws
    {
        let timeProvider = ProvenanceTestTimeProvider()
        let harness = ProvenanceHarness(timeProvider: timeProvider)
        let prepared = Self.prepared()
        let activityIdentity = Self.activityIdentity(for: prepared)
        var snapshotObserved = false
        harness.state.onSnapshot = {
            XCTAssertTrue(harness.registry.isActive(identity: activityIdentity))
            snapshotObserved = true
        }
        timeProvider.onBoundary = {
            XCTAssertTrue(snapshotObserved)
            XCTAssertEqual(harness.opener.openCount, 0)
        }

        _ = try harness.launcher.launchTracked(
            prepared: prepared,
            activityRegistry: harness.registry,
            eventHandler: { _ in }
        )

        XCTAssertEqual(harness.opener.openCount, 1)
    }

    func testTrackedLaunchForwardsPreparedArgumentsAndEnvironment() throws {
        let harness = ProvenanceHarness()
        let prepared = Self.prepared()

        _ = try harness.launcher.launchTracked(
            prepared: prepared,
            activityRegistry: harness.registry,
            eventHandler: { _ in }
        )

        XCTAssertEqual(harness.opener.lastArguments, prepared.arguments)
        XCTAssertEqual(harness.opener.lastEnvironment, prepared.environment)
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

        harness.terminationObserver.terminate(running)
        XCTAssertEqual(
            launch.currentLifecycle.state,
            .terminated(processIdentifier: 9104)
        )
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

    func testUntrackedPreparedLaunchCannotReachOpener() throws {
        let harness = ProvenanceHarness()

        XCTAssertThrowsError(
            try harness.launcher.launch(prepared: Self.prepared()) { _ in }
        ) { error in
            guard case LaunchError.trackedLaunchRequired = error else {
                return XCTFail("Expected tracked-launch-only enforcement.")
            }
        }
        XCTAssertEqual(harness.opener.openCount, 0)
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

    private enum UnknownOutcomeScenario: CaseIterable {
        case emptyBaseline
        case preexistingBaseline
        case delayedNewProcess
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

private enum ProvenanceFixtureError: LocalizedError {
    case openFailed

    var errorDescription: String? { "open failed" }
}

private extension ProfileLaunchLifecycleState {
    var isRunningForTest: Bool {
        switch self {
        case .running, .runningDegraded:
            true
        case .requested, .launching, .terminating, .terminated, .failed:
            false
        }
    }
}

final class TestWorkspaceProcessState:
    WorkspaceLaunchProcessProvenanceInspecting,
    ProcessIdentityInspecting,
    @unchecked Sendable
{
    private let lock = NSLock()
    var snapshotError: WorkspaceProcessSnapshotError?
    var preexistingProcesses: Set<WorkspaceProcessIdentity> = []
    var processInspections: [pid_t: ProcessIdentityInspection] = [:]
    var returnedInspections:
        [pid_t: [WorkspaceProcessIdentityInspection]] = [:]
    var onReturnedInspection: ((Int, pid_t) -> Void)?
    var onSnapshot: (() -> Void)?
    private var returnedInspectionCount = 0

    func snapshot(
        expectedApplication: WorkspaceApplicationBundleIdentity
    ) throws -> WorkspaceProcessSnapshot {
        onSnapshot?()
        return try lock.withLock {
            if let snapshotError { throw snapshotError }
            return WorkspaceProcessSnapshot(
                expectedApplication: expectedApplication,
                processes: preexistingProcesses
            )
        }
    }

    func inspectReturnedProcess(
        processIdentifier: pid_t,
        expectedApplication: WorkspaceApplicationBundleIdentity
    ) -> WorkspaceProcessIdentityInspection {
        let countAndInspection = lock.withLock {
            returnedInspectionCount += 1
            let count = returnedInspectionCount
            if var inspections = returnedInspections[processIdentifier],
               !inspections.isEmpty
            {
                let inspection = inspections.removeFirst()
                returnedInspections[processIdentifier] = inspections
                return (count, Optional(inspection))
            }
            return (count, Optional<WorkspaceProcessIdentityInspection>.none)
        }
        onReturnedInspection?(countAndInspection.0, processIdentifier)
        if let inspection = countAndInspection.1 { return inspection }
        switch inspect(processIdentifier: processIdentifier) {
        case .live(let process):
            return .live(
                WorkspaceProcessIdentity(
                    process: process,
                    application: expectedApplication
                )
            )
        case .dead:
            return .exited
        case .ambiguous:
            return .indeterminate
        }
    }

    func inspect(
        processIdentifier: pid_t
    ) -> ProcessIdentityInspection {
        lock.withLock {
            processInspections[processIdentifier]
                ?? .live(processIdentity(processIdentifier: processIdentifier))
        }
    }

    func processIdentity(processIdentifier: pid_t) -> ProcessStartIdentity {
        ProcessStartIdentity(
            processIdentifier: processIdentifier,
            startTimeSeconds: 10_000 + UInt64(processIdentifier),
            startTimeMicroseconds: UInt64(processIdentifier % 1_000_000)
        )
    }

    func workspaceIdentity(
        processIdentifier: pid_t,
        application: WorkspaceApplicationBundleIdentity
    ) -> WorkspaceProcessIdentity {
        WorkspaceProcessIdentity(
            process: processIdentity(processIdentifier: processIdentifier),
            application: application
        )
    }

    func markExited(processIdentifier: pid_t) {
        lock.withLock {
            processInspections[processIdentifier] = .dead
            returnedInspections[processIdentifier] = [.exited]
        }
    }
}

private final class ProvenanceHarness {
    let state = TestWorkspaceProcessState()
    let authority = WorkspaceApplicationLaunchAuthority()
    let opener = ProvenanceTestOpener()
    let timeProvider: ProvenanceTestTimeProvider

    init(
        timeProvider: ProvenanceTestTimeProvider =
            ProvenanceTestTimeProvider()
    ) {
        self.timeProvider = timeProvider
    }

    lazy var terminationObserver = ProvenanceTestTerminationObserver(state: state)
    lazy var launcher = WorkspaceApplicationLauncher(
        opener: opener,
        terminationObserver: terminationObserver,
        processProvenanceInspector: state,
        launchRequestTimeProvider: timeProvider,
        launchAuthority: authority
    )
    lazy var registry = ProfileActivityRegistry(processInspector: state)
}

private final class ProvenanceTestOpener:
    WorkspaceApplicationOpening,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var completions: [
        @Sendable (Result<any RunningApplicationInstance, Error>) -> Void
    ] = []
    private var lastCompletion:
        (@Sendable (Result<any RunningApplicationInstance, Error>) -> Void)?
    private(set) var lastActivates: Bool?
    private(set) var lastArguments: [String]?
    private(set) var lastEnvironment: [String: String]?
    var synchronousResult:
        Result<any RunningApplicationInstance, Error>?

    var openCount: Int { lock.withLock { completions.count } }

    func openApplication(
        at url: URL,
        configuration: NSWorkspace.OpenConfiguration,
        completion:
            @escaping @Sendable (Result<any RunningApplicationInstance, Error>) -> Void
    ) {
        let immediate = lock.withLock {
            lastActivates = configuration.activates
            lastArguments = configuration.arguments
            lastEnvironment = configuration.environment
            if synchronousResult == nil {
                completions.append(completion)
                lastCompletion = completion
            }
            return synchronousResult
        }
        if let immediate {
            completion(immediate)
        }
    }

    func completeNext(
        _ result: Result<any RunningApplicationInstance, Error>
    ) {
        let completion = lock.withLock { completions.removeFirst() }
        completion(result)
    }

    func replayLast(
        _ result: Result<any RunningApplicationInstance, Error>
    ) {
        lock.withLock { lastCompletion }?(result)
    }
}

final class ProvenanceTestTimeProvider:
    LaunchRequestTimeProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var boundary: LaunchRequestTimeBoundary
    var failure: LaunchRequestTimeBoundaryError?
    var onBoundary: (() -> Void)?

    init(seconds: Int64 = 0, microseconds: Int64 = 0) {
        boundary = try! LaunchRequestTimeBoundary(
            seconds: seconds,
            microseconds: microseconds
        )
    }

    func launchRequestBoundary() throws -> LaunchRequestTimeBoundary {
        onBoundary?()
        return try lock.withLock {
            if let failure { throw failure }
            return boundary
        }
    }
}

private final class ProvenanceTestRunningApplication:
    RunningApplicationInstance,
    @unchecked Sendable
{
    let processIdentifier: pid_t
    private let lock = NSLock()
    private var terminated = false

    init(processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
    }

    var isTerminated: Bool { lock.withLock { terminated } }

    func markTerminated() {
        lock.withLock { terminated = true }
    }
}

private final class ProvenanceTestTerminationObserver:
    RunningApplicationTerminationObserving,
    @unchecked Sendable
{
    private let state: TestWorkspaceProcessState
    private let lock = NSLock()
    private var callbacks: [ObjectIdentifier: @Sendable () -> Void] = [:]

    init(state: TestWorkspaceProcessState) {
        self.state = state
    }

    func observeTermination(
        of application: any RunningApplicationInstance,
        handler: @escaping @Sendable () -> Void
    ) -> any RunningApplicationTerminationObservation {
        lock.withLock { callbacks[ObjectIdentifier(application)] = handler }
        return ProvenanceTestTerminationObservation()
    }

    func terminate(_ application: ProvenanceTestRunningApplication) {
        application.markTerminated()
        state.markExited(processIdentifier: application.processIdentifier)
        lock.withLock { callbacks[ObjectIdentifier(application)] }?()
    }
}

private final class ProvenanceTestTerminationObservation:
    RunningApplicationTerminationObservation,
    @unchecked Sendable
{
    func cancel() {}
}

private final class ProvenanceLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value { lock.withLock { storage } }

    func mutate(_ body: (inout Value) -> Void) {
        lock.withLock { body(&storage) }
    }
}
