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

final class WorkspaceApplicationLauncherUnknownOutcomeTests: XCTestCase {
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


