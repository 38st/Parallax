import Darwin
import Foundation
import XCTest

@testable import Parallax

final class ActivityCacheAuditRegressionTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testUIQueriesReadCacheAndScheduledRefreshDiscoversPeerChanges() throws {
        let root = try root()
        let inspector = AuditCountingInspector()
        let scheduler = SupervisorTestScheduler()
        let registry = try ProfileActivityRegistry(
            applicationSupportURL: root,
            refreshScheduler: scheduler, processInspector: inspector)
        let identity = ProfileActivityIdentity(
            applicationID: UUID(), applicationStorageID: UUID(),
            profileID: UUID(), profileStorageID: UUID())
        let store = try DurableLaunchActivityStore(applicationSupportURL: root)
        let requestID = UUID()
        try store.createRequest(
            requestID: requestID, identity: identity, ownerProcess: inspector.owner)
        XCTAssertFalse(registry.isActive(identity: identity))
        scheduler.runNext()
        XCTAssertTrue(registry.isActive(identity: identity))
        inspector.calls.mutate { $0 = 0 }
        _ = registry.isActive(identity: identity)
        _ = registry.isStorageActive(
            applicationStorageID: identity.applicationStorageID,
            profileStorageID: identity.profileStorageID)
        _ = registry.activeProfileStorageIDs(
            applicationStorageID: identity.applicationStorageID,
            profileStorageIDs: [identity.profileStorageID])
        _ = registry.runningProcesses(applicationStorageID: identity.applicationStorageID)
        XCTAssertEqual(inspector.calls.value, 0)
        let fd = Darwin.open(
            store.rootURL.appendingPathComponent(".profile-acquisition.lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer {
            flock(fd, LOCK_UN)
            Darwin.close(fd)
        }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try store.reconciliationArtifacts())
        XCTAssertTrue(registry.isActive(identity: identity))
        flock(fd, LOCK_UN)
        try store.complete(requestID: requestID, completion: .failed)
        scheduler.runNext()
        XCTAssertFalse(registry.isActive(identity: identity))
    }

    func testOlderReconciliationCannotOverwriteNewerSnapshot() async throws {
        let root = try root()
        let inspector = AuditCountingInspector()
        let registry = try ProfileActivityRegistry(
            applicationSupportURL: root,
            refreshScheduler: SupervisorTestScheduler(), processInspector: inspector)
        let store = try DurableLaunchActivityStore(applicationSupportURL: root)
        let identity = ProfileActivityIdentity(
            applicationID: UUID(), applicationStorageID: UUID(),
            profileID: UUID(), profileStorageID: UUID())
        let id = UUID()
        try store.createRequest(requestID: id, identity: identity, ownerProcess: inspector.owner)
        let entered = expectation(description: "older reconciliation inspected its snapshot")
        let finished = expectation(description: "older reconciliation finished")
        let gate = DispatchSemaphore(value: 0)
        inspector.hook.mutate {
            $0 = {
                entered.fulfill()
                gate.wait()
            }
        }
        DispatchQueue.global().async {
            _ = try? registry.reconcileDurableActivity()
            finished.fulfill()
        }
        await fulfillment(of: [entered], timeout: 5)
        try store.complete(requestID: id, completion: .failed)
        _ = try registry.reconcileDurableActivity()
        gate.signal()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertTrue(
            registry.activeProfileStorageIDs(
                applicationStorageID: identity.applicationStorageID,
                profileStorageIDs: [identity.profileStorageID]
            ).isEmpty)
    }

    func testOpeningMarkerPrecedesSnapshot() throws {
        let root = try root()
        let harness = LifecycleHarness()
        let store = try DurableLaunchActivityStore(applicationSupportURL: root)
        let registry = try ProfileActivityRegistry(
            applicationSupportURL: root,
            refreshScheduler: SupervisorTestScheduler(), processInspector: harness.processState)
        let inspector = AuditSnapshotInspector(state: harness.processState, store: store)
        let launcher = WorkspaceApplicationLauncher(
            opener: harness.opener,
            terminationObserver: harness.terminationObserver, processProvenanceInspector: inspector,
            launchRequestTimeProvider: ProvenanceTestTimeProvider())
        let launch = try launcher.launchTracked(
            prepared: harness.prepared(requestID: UUID()),
            activityRegistry: registry, eventHandler: { _ in })
        XCTAssertTrue(inspector.sawOpening.value)
        launch.didFail(AuditCacheError.finished)
    }
}

private enum AuditCacheError: Error { case finished }

private final class AuditCountingInspector: ProcessIdentityInspecting, Sendable {
    let owner = ProcessStartIdentity(
        processIdentifier: 7891, startTimeSeconds: 100, startTimeMicroseconds: 0)
    let calls = LaunchTestLocked(0)
    let hook = LaunchTestLocked<(@Sendable () -> Void)?>(nil)
    func inspect(processIdentifier: pid_t) -> ProcessIdentityInspection {
        calls.mutate { $0 += 1 }
        var action: (@Sendable () -> Void)?
        hook.mutate { value in
            action = value
            value = nil
        }
        action?()
        return .live(owner)
    }
}

private struct AuditSnapshotInspector: WorkspaceLaunchProcessProvenanceInspecting {
    let state: TestWorkspaceProcessState
    let store: DurableLaunchActivityStore
    let sawOpening = LaunchTestLocked(false)
    func snapshot(expectedApplication: WorkspaceApplicationBundleIdentity) throws
        -> WorkspaceProcessSnapshot
    {
        sawOpening.mutate { value in
            value = store.artifacts().contains {
                if case .opening = $0.state { return true }
                return false
            }
        }
        return try state.snapshot(expectedApplication: expectedApplication)
    }
    func inspectReturnedProcess(
        processIdentifier: pid_t,
        expectedApplication: WorkspaceApplicationBundleIdentity
    ) -> WorkspaceProcessIdentityInspection {
        state.inspectReturnedProcess(
            processIdentifier: processIdentifier, expectedApplication: expectedApplication)
    }
}
