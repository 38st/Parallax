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

final class WorkspaceApplicationLauncherFIFOTests: XCTestCase {
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
    func testUnknownOutcomeNeverAdvancesFIFOAfterObservedConsumerExactDeath()
        throws
    {
        let state = TestWorkspaceProcessState()
        let scheduler = SupervisorTestScheduler()
        let supervisor = WorkspaceProcessSupervisor(
            inspector: state,
            scheduler: scheduler,
            pollInterval: 1
        )
        let authority = WorkspaceApplicationLaunchAuthority()
        let firstOpener = ProvenanceTestOpener()
        let secondOpener = ProvenanceTestOpener()
        let firstLauncher = WorkspaceApplicationLauncher(
            opener: firstOpener,
            terminationObserver:
                ProvenanceTestTerminationObserver(state: state),
            processProvenanceInspector: state,
            launchRequestTimeProvider: ProvenanceTestTimeProvider(),
            processSupervisor: supervisor,
            launchAuthority: authority
        )
        let secondLauncher = WorkspaceApplicationLauncher(
            opener: secondOpener,
            terminationObserver:
                ProvenanceTestTerminationObserver(state: state),
            processProvenanceInspector: state,
            launchRequestTimeProvider: ProvenanceTestTimeProvider(),
            processSupervisor: supervisor,
            launchAuthority: authority
        )
        let firstPrepared = Self.prepared()
        let secondPrepared = Self.prepared()
        let firstRegistry = ProfileActivityRegistry(processInspector: state)
        let secondRegistry = ProfileActivityRegistry(processInspector: state)
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
        firstOpener.completeNext(
            .failure(ProvenanceFixtureError.openFailed)
        )
        XCTAssertEqual(secondOpener.openCount, 0)
        XCTAssertEqual(
            scheduler.pendingCount,
            0,
            "Unknown opener outcomes have no automatic recovery scheduler"
        )
        scheduler.runNext()
        XCTAssertEqual(secondOpener.openCount, 0)

        let delayed = state.workspaceIdentity(
            processIdentifier: 9_116,
            application: firstPrepared.applicationIdentity
        )
        state.preexistingProcesses = [delayed]
        scheduler.runNext()
        XCTAssertEqual(secondOpener.openCount, 0)

        state.markExited(processIdentifier: delayed.processIdentifier)
        state.preexistingProcesses = []
        scheduler.runNext()
        scheduler.runAll()
        XCTAssertEqual(first.currentLifecycle.state, .launching)
        XCTAssertTrue(
            firstRegistry.isActive(
                identity: Self.activityIdentity(for: firstPrepared)
            )
        )
        XCTAssertEqual(secondOpener.openCount, 0)

        let later = state.workspaceIdentity(
            processIdentifier: 9_120,
            application: firstPrepared.applicationIdentity
        )
        state.preexistingProcesses = [later]
        state.markExited(processIdentifier: later.processIdentifier)
        state.preexistingProcesses = []
        scheduler.runAll()
        XCTAssertEqual(
            secondOpener.openCount,
            0,
            "No snapshot/death sequence causally exhausts an unknown opener outcome"
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
        guard case .failed = second.currentLifecycle.state else {
            return XCTFail("The second singleton result must be refused.")
        }
        XCTAssertEqual(
            second.currentLifecycle.openingDisposition,
            .preExistingSingletonRefused(processIdentifier: 9103)
        )
        XCTAssertEqual(singleton.activationCount, 1)
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
    private enum UnknownOutcomeScenario: CaseIterable {
        case emptyBaseline
        case preexistingBaseline
        case delayedNewProcess
    }
}


