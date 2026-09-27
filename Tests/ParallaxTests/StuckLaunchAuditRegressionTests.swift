import Foundation
import XCTest
@testable import Parallax

final class StuckLaunchAuditRegressionTests: XCTestCase {
    private let owner = ProcessStartIdentity(processIdentifier: 7001, startTimeSeconds: 20, startTimeMicroseconds: 0)
    private let application = WorkspaceApplicationBundleIdentity(bundleURL: URL(fileURLWithPath: "/Synthetic/App.app"), bundleIdentifier: "test.fixture")

    private func fixture() throws -> (DurableLaunchActivityStore, ProfileActivityRegistry, TestWorkspaceProcessState, ProfileActivityIdentity, UUID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Parallax-Stuck-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try DurableLaunchActivityStore(applicationSupportURL: root)
        let state = TestWorkspaceProcessState()
        state.processInspections[owner.processIdentifier] = .dead
        let registry = try ProfileActivityRegistry(applicationSupportURL: root, processInspector: state)
        let identity = ProfileActivityIdentity(applicationID: UUID(), applicationStorageID: UUID(), profileID: UUID(), profileStorageID: UUID())
        let id = UUID()
        try store.createRequest(requestID: id, identity: identity, ownerProcess: owner)
        try store.markOpening(requestID: id)
        _ = try registry.reconcileDurableActivity()
        return (store, registry, state, identity, id)
    }

    func testMatchingProcessMakesClearUnavailableAndRevokesPriorConfirmation() throws {
        let (_, registry, _, identity, _) = try fixture()
        let probe = StuckProcessProbe(application: application)
        let records = try registry.stuckLaunchRecords(identity: identity, expectedApplication: application, processSnapshotter: probe)
        XCTAssertEqual(records.count, 1)
        probe.running.mutate { $0 = true }
        XCTAssertTrue(try registry.stuckLaunchRecords(identity: identity, expectedApplication: application, processSnapshotter: probe).isEmpty)
        XCTAssertThrowsError(try registry.clearStuckLaunchRecords(records, identity: identity, expectedApplication: application, processSnapshotter: probe))
        XCTAssertTrue(registry.isActive(identity: identity))
    }

    func testReceiptChangedSinceConfirmationCannotBeCleared() throws {
        let (store, registry, _, identity, id) = try fixture()
        let probe = StuckProcessProbe(application: application)
        let records = try registry.stuckLaunchRecords(identity: identity, expectedApplication: application, processSnapshotter: probe)
        XCTAssertEqual(records.count, 1)
        try store.recordProcess(requestID: id, process: owner)
        XCTAssertThrowsError(try registry.clearStuckLaunchRecords(records, identity: identity, expectedApplication: application, processSnapshotter: probe))
        XCTAssertEqual(store.artifacts().count, 1)
    }

    func testSuccessfulClearUnblocksOnlyConfirmedSpace() throws {
        let (store, registry, _, identity, _) = try fixture()
        let other = ProfileActivityIdentity(applicationID: identity.applicationID, applicationStorageID: identity.applicationStorageID,
                                           profileID: UUID(), profileStorageID: UUID())
        let otherID = UUID()
        try store.createRequest(requestID: otherID, identity: other, ownerProcess: owner)
        try store.markOpening(requestID: otherID)
        _ = try registry.reconcileDurableActivity()
        let probe = StuckProcessProbe(application: application)
        let records = try registry.stuckLaunchRecords(identity: identity, expectedApplication: application, processSnapshotter: probe)
        XCTAssertEqual(records.count, 1)
        try registry.clearStuckLaunchRecords(records, identity: identity, expectedApplication: application, processSnapshotter: probe)
        XCTAssertFalse(registry.isActive(identity: identity))
        XCTAssertTrue(registry.isActive(identity: other))
        XCTAssertEqual(store.artifacts().map(\.requestID), [otherID])
    }

    func testRewrittenOpeningReceiptFailsExactSnapshotCheck() throws {
        let (store, registry, _, identity, id) = try fixture()
        let probe = StuckProcessProbe(application: application)
        let records = try registry.stuckLaunchRecords(identity: identity, expectedApplication: application, processSnapshotter: probe)
        XCTAssertEqual(records.count, 1)
        let path = store.rootURL.appendingPathComponent(id.uuidString.lowercased()).appendingPathComponent("request.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var ownerObject = try XCTUnwrap(object["ownerProcess"] as? [String: Any])
        ownerObject["startTimeSeconds"] = 21
        object["ownerProcess"] = ownerObject
        try JSONSerialization.data(withJSONObject: object, options: .sortedKeys).write(to: path)
        XCTAssertThrowsError(try registry.clearStuckLaunchRecords(records, identity: identity, expectedApplication: application, processSnapshotter: probe))
        XCTAssertEqual(store.artifacts().count, 1)
    }

    func testUnverifiableProcessesAndExtraReceiptFilesKeepActionUnavailable() throws {
        let (store, registry, _, identity, id) = try fixture()
        let probe = StuckProcessProbe(application: application)
        probe.unavailable.mutate { $0 = true }
        XCTAssertThrowsError(try registry.stuckLaunchRecords(identity: identity, expectedApplication: application, processSnapshotter: probe))
        probe.unavailable.mutate { $0 = false }
        let extra = store.rootURL.appendingPathComponent(id.uuidString.lowercased()).appendingPathComponent("unknown.json")
        try Data("unknown".utf8).write(to: extra)
        XCTAssertTrue(try registry.stuckLaunchRecords(identity: identity, expectedApplication: application, processSnapshotter: probe).isEmpty)
    }

    @MainActor
    func testConfirmationProcessCheckHoldsInterprocessActivityLock() throws {
        let (peerStore, registry, _, identity, id) = try fixture()
        var probe = StuckProcessProbe(application: application)
        let records = try registry.stuckLaunchRecords(identity: identity, expectedApplication: application, processSnapshotter: probe)
        let observedLock = LaunchTestLocked(false)
        probe.onSnapshot = {
            do {
                try peerStore.recordProcess(requestID: id, process: .init(processIdentifier: 7002,
                    startTimeSeconds: 30, startTimeMicroseconds: 0))
                XCTFail("The process check must hold the receipt lock")
            } catch DurableLaunchActivityStoreError.activityBusy {
                observedLock.mutate { $0 = true }
            }
        }
        try registry.clearStuckLaunchRecords(records, identity: identity, expectedApplication: application, processSnapshotter: probe)
        XCTAssertTrue(observedLock.value)
        XCTAssertFalse(registry.isActive(identity: identity))
    }

    @MainActor
    func testStoreConfirmationRejectsChangedSpaceThenClearsExactTarget() throws {
        let (journal, registry, _, identity, _) = try fixture()
        let root = journal.rootURL.deletingLastPathComponent().deletingLastPathComponent()
        let profile = LaunchProfile(id: identity.profileID, storageID: identity.profileStorageID, name: "Work")
        let app = ManagedApplication(id: identity.applicationID, storageID: identity.applicationStorageID,
            displayName: "Fixture", bundleIdentifier: application.bundleIdentifier, appPath: application.bundleURL.path,
            baseStoragePath: root.path, profiles: [profile])
        let repository = LibraryRepository(applicationSupportURL: root)
        _ = try repository.save([app], expectedVersion: .missing)
        let store = LibraryStore(repository: repository, profileActivityRegistry: registry, settings: AppSettings())
        let probe = StuckProcessProbe(application: application)
        let request = try XCTUnwrap(store.stuckLaunchRecoveryRequest(for: app, profile: profile, processSnapshotter: probe))
        store.applications[0].profiles[0].environmentText = "CHANGED=yes"
        XCTAssertFalse(store.confirmClearStuckLaunchRecord(request, processSnapshotter: probe))
        XCTAssertTrue(registry.isActive(identity: identity))
        store.applications = [app]
        XCTAssertTrue(store.confirmClearStuckLaunchRecord(request, processSnapshotter: probe))
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(registry.isActive(identity: identity))
        XCTAssertNil(store.stuckLaunchRecoveryRequest(for: app, profile: profile, processSnapshotter: probe))
    }

    func testLiveOwnerCannotBeMistakenForInterruptedCleanup() throws {
        let (_, registry, state, identity, _) = try fixture()
        state.processInspections[owner.processIdentifier] = .live(owner)
        XCTAssertTrue(try registry.stuckLaunchRecords(identity: identity, expectedApplication: application,
            processSnapshotter: StuckProcessProbe(application: application)).isEmpty)
    }
}

private struct StuckProcessProbe: WorkspaceLaunchProcessProvenanceInspecting {
    let application: WorkspaceApplicationBundleIdentity
    let running = LaunchTestLocked(false)
    let unavailable = LaunchTestLocked(false)
    var onSnapshot: (@Sendable () throws -> Void)?

    func snapshot(expectedApplication: WorkspaceApplicationBundleIdentity) throws -> WorkspaceProcessSnapshot {
        try onSnapshot?()
        if unavailable.value { throw WorkspaceProcessSnapshotError.processListUnavailable }
        let processes: Set<WorkspaceProcessIdentity> = running.value ? [.init(process: .init(processIdentifier: 7002,
            startTimeSeconds: 30, startTimeMicroseconds: 0), application: application)] : []
        return .init(expectedApplication: expectedApplication, processes: processes)
    }

    func inspectReturnedProcess(processIdentifier: Int32, expectedApplication: WorkspaceApplicationBundleIdentity) -> WorkspaceProcessIdentityInspection {
        .indeterminate
    }
}
