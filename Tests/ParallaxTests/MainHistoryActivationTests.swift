import Foundation
import XCTest
@testable import Parallax

@MainActor
final class MainHistoryActivationTests: XCTestCase {
    func testActivationFinishesRequestAndShowsSuccessWithoutRunningHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MainHistory-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = LifecycleHarness()
        let registry = try ProfileActivityRegistry(applicationSupportURL: root,
            refreshScheduler: SupervisorTestScheduler(), processInspector: harness.processState,
            completionScheduler: SupervisorTestScheduler())
        var prepared = harness.prepared(requestID: UUID())
        prepared.usesSharedCodexWorkspace = true
        let exact = harness.processState.workspaceIdentity(processIdentifier: 9181, application: prepared.applicationIdentity)
        harness.processState.preexistingProcesses = [exact]
        let profile = LaunchProfile(id: prepared.profileID, storageID: prepared.profileStorageID, name: "Main")
        let app = ManagedApplication(id: prepared.applicationID, storageID: prepared.applicationStorageID,
            displayName: "Synthetic Codex", bundleIdentifier: prepared.applicationIdentity.bundleIdentifier,
            appPath: prepared.applicationURL.path, baseStoragePath: root.path, profiles: [profile])
        let repository = LibraryRepository(applicationSupportURL: root)
        _ = try repository.save([app], expectedVersion: .missing)
        let store = LibraryStore(repository: repository, profileActivityRegistry: registry, settings: AppSettings())
        XCTAssertTrue(store.registerDirectLaunchIfNeeded(application: app, profile: profile,
            source: store.launchConfigurationSource(application: app, profile: profile, requestID: prepared.requestID)))
        let launch = try harness.launcher.launchTracked(prepared: prepared, activityRegistry: registry, eventHandler: { _ in })
        store.retainTrackedLaunch(launch, requestID: prepared.requestID)
        harness.opener.completeNext(.success(ExactRunningApplicationHandle(processIdentifier: 9181)))
        store.handleLaunchLifecycle(launch.currentLifecycle, profileName: profile.name)
        XCTAssertNil(store.activeTrackedLaunches[prepared.requestID])
        XCTAssertEqual(store.launchRequests.status(for: prepared.requestID)?.state, .mainHistoryActivated)
        XCTAssertEqual(store.launchStatusPresentation(for: app, profile: profile)?.tone, .success)
        XCTAssertEqual(store.launchStatusMessage(for: app, profile: profile),
            String(localized: "Brought the running Codex forward. It uses the main history."))
        XCTAssertFalse(store.isSpaceRunning(application: app, profile: profile))
        XCTAssertFalse(registry.isActive(identity: harness.identity))
        XCTAssertFalse(try registry.hasDurableRecord(for: exact.process, excluding: UUID()))
        XCTAssertTrue(store.launchHistoryStore.entries(for: app).isEmpty)
        XCTAssertFalse(store.updateLaunchRequestStatus(requestID: prepared.requestID, state: .launching))
    }

    func testRecoveredDurableIsolatedProcessRefusesMainHistoryActivation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MainHistory-Durable-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = LifecycleHarness()
        let registry = try ProfileActivityRegistry(applicationSupportURL: root,
            refreshScheduler: SupervisorTestScheduler(), processInspector: harness.processState,
            completionScheduler: SupervisorTestScheduler())
        let isolatedID = UUID()
        let lease = try registry.acquireLaunchLease(identity: harness.identity, requestID: isolatedID)
        defer { lease.release() }
        let exact = harness.processState.workspaceIdentity(processIdentifier: 9182,
            application: harness.prepared(requestID: UUID()).applicationIdentity)
        try registry.recordRunningProcess(requestID: isolatedID, processIdentity: exact.process)
        // Recreate the registry so the check also covers recovered records.
        let recovered = try ProfileActivityRegistry(applicationSupportURL: root,
            refreshScheduler: SupervisorTestScheduler(), processInspector: harness.processState,
            completionScheduler: SupervisorTestScheduler())
        let other = ProfileActivityIdentity(applicationID: harness.identity.applicationID,
            applicationStorageID: harness.identity.applicationStorageID, profileID: UUID(), profileStorageID: UUID())
        var prepared = harness.prepared(requestID: UUID(), identity: other)
        prepared.usesSharedCodexWorkspace = true
        harness.processState.preexistingProcesses = [exact]
        let launch = try harness.launcher.launchTracked(prepared: prepared, activityRegistry: recovered, eventHandler: { _ in })
        harness.opener.completeNext(.success(ExactRunningApplicationHandle(processIdentifier: 9182)))
        guard case .failed = launch.currentLifecycle.state else { return XCTFail("Must refuse recovered isolated process") }
        XCTAssertNil(launch.currentLifecycle.processIdentity)
        XCTAssertFalse(recovered.isActive(identity: other))
        XCTAssertTrue(try recovered.hasDurableRecord(for: exact.process, excluding: prepared.requestID))
        XCTAssertNil(ProcessWideLaunchSupervision.shared.launch(requestID: prepared.requestID))
        XCTAssertEqual(harness.terminationObserver.observationCount, 0)
    }
}
