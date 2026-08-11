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
private typealias ProvenanceTestTerminationObservation =
    TestRunningApplicationTerminationObservation
private typealias ProvenanceLocked<Value> = LaunchTestLocked<Value>

final class WorkspaceApplicationLauncherAdmissionTests: XCTestCase {
    func testPreopenFailureRollsBackRequestGateWithoutCallingOpener() throws {
        let state = TestWorkspaceProcessState()
        state.snapshotError = .processListUnavailable
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
        XCTAssertEqual(observer.observationCount, 0)
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
        guard case .failed = launch.currentLifecycle.state else {
            return XCTFail("A pre-existing singleton must be a terminal refusal.")
        }
        XCTAssertEqual(
            launch.currentLifecycle.openingDisposition,
            .preExistingSingletonRefused(processIdentifier: 9110)
        )
        XCTAssertFalse(registry.isActive(identity: activityIdentity))
        XCTAssertEqual(observer.observationCount, 0)
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
        XCTAssertEqual(running.activationCount, 1)
        XCTAssertTrue(harness.authority.isClaimed(exact, requestID: prepared.requestID))
    }

    func testPreExistingProcessIsTerminalWithoutObservationOrRetainedGate()
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
        guard case .failed(let message) = launch.currentLifecycle.state else {
            return XCTFail("Expected terminal singleton refusal.")
        }
        XCTAssertTrue(message.contains("pre-existing process"))
        XCTAssertEqual(
            launch.currentLifecycle.openingDisposition,
            .preExistingSingletonRefused(processIdentifier: 9102)
        )
        XCTAssertNil(launch.currentLifecycle.processIdentity)
        XCTAssertFalse(events.value.contains { event in
            if case .running = event { return true }
            return false
        })
        XCTAssertTrue(events.value.contains { event in
            if case .failed = event { return true }
            return false
        })
        XCTAssertFalse(
            harness.registry.isActive(
                identity: Self.activityIdentity(for: prepared)
            )
        )
        XCTAssertEqual(harness.terminationObserver.observationCount, 0)
        XCTAssertEqual(running.activationCount, 0)
    }

    func testPreExistingRefusalPhysicallyRemovesDurableRequestReceipt()
        throws
    {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Parallax-PreExisting-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: support,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: support) }

        let state = TestWorkspaceProcessState()
        let opener = ProvenanceTestOpener()
        let observer = ProvenanceTestTerminationObserver(state: state)
        let launcher = WorkspaceApplicationLauncher(
            opener: opener,
            terminationObserver: observer,
            processProvenanceInspector: state,
            launchRequestTimeProvider: ProvenanceTestTimeProvider()
        )
        let registry = try ProfileActivityRegistry(
            applicationSupportURL: support,
            processInspector: state
        )
        let prepared = Self.prepared()
        let exact = state.workspaceIdentity(
            processIdentifier: 9_112,
            application: prepared.applicationIdentity
        )
        state.preexistingProcesses = [exact]
        let launch = try launcher.launchTracked(
            prepared: prepared,
            activityRegistry: registry,
            eventHandler: { _ in }
        )
        let requestDirectory = support
            .appendingPathComponent("Parallax", isDirectory: true)
            .appendingPathComponent("ActiveLaunches", isDirectory: true)
            .appendingPathComponent(
                prepared.requestID.uuidString.lowercased(),
                isDirectory: true
            )
        XCTAssertTrue(FileManager.default.fileExists(atPath: requestDirectory.path))

        opener.completeNext(
            .success(
                ProvenanceTestRunningApplication(processIdentifier: 9_112)
            )
        )

        guard case .failed = launch.currentLifecycle.state else {
            return XCTFail("Pre-existing singleton must be terminally refused.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestDirectory.path))
        XCTAssertTrue(
            registry.runningProcesses(
                applicationStorageID: prepared.applicationStorageID
            ).isEmpty
        )
    }

    func testDirectLaunchAuthorityCollisionIsTerminalRefusal() throws {
        let harness = ProvenanceHarness()
        let prepared = Self.prepared()
        let exact = harness.state.workspaceIdentity(
            processIdentifier: 9_113,
            application: prepared.applicationIdentity
        )
        XCTAssertTrue(harness.authority.claim(exact, requestID: UUID()))
        harness.state.returnedInspections[9_113] = [
            .live(exact), .live(exact), .live(exact),
        ]
        let launch = try harness.launcher.launchTracked(
            prepared: prepared,
            activityRegistry: harness.registry,
            eventHandler: { _ in }
        )
        let running = ProvenanceTestRunningApplication(
            processIdentifier: 9_113
        )

        harness.opener.completeNext(.success(running))

        guard case .failed = launch.currentLifecycle.state else {
            return XCTFail("An existing exact claim must be terminally refused.")
        }
        XCTAssertEqual(
            launch.currentLifecycle.openingDisposition,
            .preExistingSingletonRefused(processIdentifier: 9_113)
        )
        XCTAssertFalse(
            harness.registry.isActive(
                identity: Self.activityIdentity(for: prepared)
            )
        )
        XCTAssertEqual(harness.terminationObserver.observationCount, 0)
        XCTAssertEqual(running.activationCount, 0)
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

}
