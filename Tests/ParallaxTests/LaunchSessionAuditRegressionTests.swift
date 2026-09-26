import Foundation
import XCTest

@testable import Parallax

final class LaunchSessionAuditRegressionTests: XCTestCase {
    func testQueuedLaunchHasNoOpeningMarkerBeforeSubmission() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let harness = LifecycleHarness()
        let registry = try ProfileActivityRegistry(
            applicationSupportURL: root, processInspector: harness.processState)
        let first = try harness.launcher.launchTracked(
            prepared: harness.prepared(requestID: UUID()), activityRegistry: registry,
            eventHandler: { _ in })
        let identity = ProfileActivityIdentity(
            applicationID: UUID(), applicationStorageID: UUID(), profileID: UUID(),
            profileStorageID: UUID())
        let secondID = UUID()
        let second = try harness.launcher.launchTracked(
            prepared: harness.prepared(requestID: secondID, identity: identity),
            activityRegistry: registry, eventHandler: { _ in })
        let store = try DurableLaunchActivityStore(applicationSupportURL: root)
        let artifact = try XCTUnwrap(store.artifacts().first { $0.requestID == secondID })
        guard case .requestOnly = artifact.state else {
            return XCTFail("Queued work has not submitted an open")
        }
        first.didFail(AuditSessionError.cancelled)
        second.didFail(AuditSessionError.cancelled)
    }

    func testDeclinedQuitRestoresRunningAndLaterExitIsUnexpected() throws {
        let harness = LifecycleHarness()
        let scheduler = SupervisorTestScheduler()
        let launcher = WorkspaceApplicationLauncher(
            opener: harness.opener,
            terminationObserver: harness.terminationObserver,
            processProvenanceInspector: harness.processState,
            launchRequestTimeProvider: ProvenanceTestTimeProvider(),
            processSupervisor: WorkspaceProcessSupervisor(
                inspector: harness.processState, scheduler: scheduler)
        )
        let launch = try launcher.launchTracked(
            prepared: harness.prepared(requestID: UUID()), activityRegistry: harness.registry,
            eventHandler: { _ in })
        let running = ExactRunningApplicationHandle(processIdentifier: 7124)
        harness.opener.complete(.success(running))
        try launch.performTerminationRequest {}
        XCTAssertEqual(launch.currentLifecycle.state, .terminating(processIdentifier: 7124))
        scheduler.runNext()
        scheduler.runNext()
        XCTAssertEqual(launch.currentLifecycle.state, .running(processIdentifier: 7124))
        harness.terminationObserver.terminate(running)
        XCTAssertEqual(launch.currentLifecycle.terminationDisposition, .unexpected)
    }

    func testDeclinedQuitRetriesTransientIdentityUnavailability() throws {
        let harness = LifecycleHarness()
        let scheduler = SupervisorTestScheduler()
        let launcher = WorkspaceApplicationLauncher(
            opener: harness.opener,
            terminationObserver: harness.terminationObserver,
            processProvenanceInspector: harness.processState,
            launchRequestTimeProvider: ProvenanceTestTimeProvider(),
            processSupervisor: WorkspaceProcessSupervisor(
                inspector: harness.processState, scheduler: scheduler)
        )
        let launch = try launcher.launchTracked(
            prepared: harness.prepared(requestID: UUID()), activityRegistry: harness.registry,
            eventHandler: { _ in })
        let running = ExactRunningApplicationHandle(processIdentifier: 7134)
        harness.opener.complete(.success(running))
        try launch.performTerminationRequest {}
        harness.processState.returnedInspections[7134] = [.indeterminate, .indeterminate]
        scheduler.runNext()
        scheduler.runNext()
        XCTAssertEqual(launch.currentLifecycle.state, .terminating(processIdentifier: 7134))
        scheduler.runNext()
        scheduler.runNext()
        XCTAssertEqual(launch.currentLifecycle.state, .running(processIdentifier: 7134))
        harness.terminationObserver.terminate(running)
        XCTAssertEqual(launch.currentLifecycle.terminationDisposition, .unexpected)
    }

    func testIndeterminateProcessIsPolledWhenTerminationNotificationIsMissing() throws {
        let harness = LifecycleHarness()
        let scheduler = SupervisorTestScheduler()
        let launcher = WorkspaceApplicationLauncher(
            opener: harness.opener,
            terminationObserver: harness.terminationObserver,
            processProvenanceInspector: harness.processState,
            launchRequestTimeProvider: ProvenanceTestTimeProvider(),
            processSupervisor: WorkspaceProcessSupervisor(
                inspector: harness.processState, scheduler: scheduler)
        )
        let prepared = harness.prepared(requestID: UUID())
        harness.processState.returnedInspections[7125] = [.indeterminate]
        let launch = try launcher.launchTracked(
            prepared: prepared, activityRegistry: harness.registry, eventHandler: { _ in })
        harness.opener.complete(.success(ExactRunningApplicationHandle(processIdentifier: 7125)))
        XCTAssertEqual(launch.currentLifecycle.state, .launching)
        harness.processState.markExited(processIdentifier: 7125)
        scheduler.runNext()
        XCTAssertTrue(launch.currentLifecycle.state.isTerminal)
        XCTAssertFalse(harness.registry.isActive(identity: harness.identity))
    }

    func testIndeterminateClaimPublishesDiagnosticLifecycle() throws {
        let harness = LifecycleHarness()
        let prepared = harness.prepared(requestID: UUID())
        let original = harness.processState.workspaceIdentity(
            processIdentifier: 7123, application: prepared.applicationIdentity)
        let changed = WorkspaceProcessIdentity(
            process: original.process,
            application: WorkspaceApplicationBundleIdentity(
                bundleURL: URL(fileURLWithPath: "/synthetic/Changed.app"),
                bundleIdentifier: "changed"))
        harness.processState.returnedInspections[7123] = [.live(original), .live(changed)]
        let launch = try harness.launcher.launchTracked(
            prepared: prepared, activityRegistry: harness.registry, eventHandler: { _ in })
        harness.opener.complete(.success(ExactRunningApplicationHandle(processIdentifier: 7123)))
        guard case .provenanceIndeterminate = launch.currentLifecycle.openingDisposition else {
            return XCTFail("Must publish blocked provenance")
        }
    }
}

private enum AuditSessionError: Error { case cancelled }
