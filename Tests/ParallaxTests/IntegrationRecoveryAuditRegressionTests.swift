import Foundation
import XCTest
@testable import Parallax

@MainActor
final class IntegrationRecoveryAuditRegressionTests: XCTestCase {
    func testRemovalConflictSurvivesCloseRelaunchAndPeerReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try RemovalAuditFixture(root: root, choice: .delete, createData: true)
        try f.interrupt(after: .stageProfile(f.application.profiles[0].storageID, 0))
        try FileManager.default.createDirectory(at: f.sources[0], withIntermediateDirectories: true)
        for _ in 0..<2 {
            let store = LibraryStore(repository: f.repository, applicationRemovalTransactions: try f.coordinator(),
                profileActivityRegistry: ProfileActivityRegistry(), settings: AppSettings())
            XCTAssertTrue(store.isPendingApplicationRemovalRecovery)
            XCTAssertNotNil(store.applicationRemovalRecoveryDetail)
            XCTAssertNil(store.startOverAuthorization())
            await store.refreshApplicationRemovalRecoveryReviews()
            XCTAssertEqual(store.pendingApplicationRemovalRecoveries.count, 1)
            store.isShowingApplicationRemovalConfirmation = false
            XCTAssertTrue(store.isPendingApplicationRemovalRecovery)
            store.reloadFromSharedRepository()
            XCTAssertTrue(store.isPendingApplicationRemovalRecovery)
        }
        let store = LibraryStore(repository: f.repository, applicationRemovalTransactions: try f.coordinator(),
            profileActivityRegistry: ProfileActivityRegistry(), settings: AppSettings())
        await store.refreshApplicationRemovalRecoveryReviews()
        store.keepApplicationRemovalFilesAndContinue(try XCTUnwrap(store.pendingApplicationRemovalRecoveries.first))
        XCTAssertTrue(store.canMutateLibrary())
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.sources[0].path))
    }

    func testStartupRelocationMaintenanceRunsWithoutPendingPlans() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let temp = f.coordinator.controlRootURL.appendingPathComponent(".\(UUID().uuidString.lowercased()).pending")
        try Data("partial".utf8).write(to: temp)
        let store = LibraryStore(repository: f.repository, storageRelocationCoordinator: f.coordinator,
            profileActivityRegistry: f.registry, settings: AppSettings())
        XCTAssertEqual(store.applications, [f.application])
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
    }

    func testStartupRelocationReservationConflictRetries() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        try f.publishPlan(preview)
        let profile = try XCTUnwrap(f.application.profiles.first)
        let reservation = try f.registry.acquireDataOperationLease(identities: [.init(applicationID: f.application.id,
            applicationStorageID: f.application.storageID, profileID: profile.id, profileStorageID: profile.storageID)])
        let store = LibraryStore(repository: f.repository, storageRelocationCoordinator: f.coordinator,
            profileActivityRegistry: f.registry, settings: AppSettings())
        XCTAssertEqual(store.applications, [f.application])
        XCTAssertTrue(store.isLibraryOperationInProgress)
        XCTAssertNil(store.startOverAuthorization())
        reservation.release()
        store.retryBusyLibraryLoad()
        XCTAssertFalse(store.isLibraryOperationInProgress)
        XCTAssertTrue(try f.coordinator.pendingRelocations().isEmpty)
    }

    func testStartupShowsRecordedRelocationLeftovers() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        try f.publishPlan(preview)
        let plan = try f.coordinator.loadControlPlan(preview.requestID)
        let path = preview.source.applicationRoot.url.path
        _ = try f.coordinator.writeControlReceipt(plan: plan, completion: .committed, leftoverSourcePaths: [path])
        let store = LibraryStore(repository: f.repository, storageRelocationCoordinator: f.coordinator,
            profileActivityRegistry: f.registry, settings: AppSettings())
        XCTAssertTrue(store.libraryOperationStatusMessage?.contains(path) == true)
        store.dismissLibraryOperationStatus()
        XCTAssertTrue(try f.coordinator.recordedLeftoverSourcePaths().isEmpty)
        store.reloadFromSharedRepository()
        XCTAssertNil(store.libraryOperationStatusMessage)
        let reopened = LibraryStore(repository: f.repository, storageRelocationCoordinator: f.coordinator,
            profileActivityRegistry: f.registry, settings: AppSettings())
        XCTAssertNil(reopened.libraryOperationStatusMessage)
        XCTAssertTrue(try f.coordinator.pendingRelocations().isEmpty)
    }
}

extension IntegrationRecoveryAuditRegressionTests {
    func testStartupRemovalReservesEveryManifestProfileDuringRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try RemovalAuditFixture(root: root, choice: .delete, createData: true)
        try f.interrupt(after: .stageProfile(f.application.profiles[0].storageID, 0))
        // Keep both the peer and recovery registries' refreshes under test control.
        let refreshScheduler = SupervisorTestScheduler()
        let peer = try ProfileActivityRegistry(applicationSupportURL: root, refreshScheduler: refreshScheduler)
        let identities = f.application.profiles.map { ProfileActivityIdentity(applicationID: f.application.id,
            applicationStorageID: f.application.storageID, profileID: $0.id, profileStorageID: $0.storageID) }
        let observed = LaunchTestLocked(0)
        let coordinator = try ApplicationRemovalTransactionCoordinator(applicationSupportURL: root, identitySource: { secure in
            observed.mutate { $0 += 1 }
            for identity in identities {
                XCTAssertThrowsError(try peer.acquireLaunchLease(identity: identity, requestID: UUID())) { error in
                    guard case ProfileActivityRegistryError.storageReservedForDataOperation = error else {
                        return XCTFail("Expected a recovery reservation, got \(error)")
                    }
                }
            }
            return try ApplicationRemovalTransactionRootIdentity.read(secure)
        }, activityRefreshScheduler: refreshScheduler)
        let store = LibraryStore(repository: f.repository, applicationRemovalTransactions: coordinator,
            profileActivityRegistry: peer, settings: AppSettings())
        XCTAssertEqual(store.applications, [f.application])
        XCTAssertGreaterThan(observed.value, 0)
        XCTAssertTrue(try coordinator.pendingTransactions().isEmpty)
        for identity in identities {
            let id = UUID()
            let lease = try peer.acquireLaunchLease(identity: identity, requestID: id)
            try peer.completeDurableLaunch(requestID: id, completion: .terminated)
            lease.release()
        }
    }

    func testRecoveryControlsRemainReachableAndRelocationChangeIsDisabled() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let emptyStates = try String(contentsOf: root.appendingPathComponent("Sources/Parallax/Views/EmptyStates.swift"))
        let recoveryButton = try XCTUnwrap(emptyStates.range(of: "ApplicationRemovalRecoveryButton(store: store)"))
        let repairCondition = try XCTUnwrap(emptyStates.range(of: "if canAttemptRecovery {"))
        XCTAssertLessThan(recoveryButton.lowerBound, repairCondition.lowerBound)
        let content = try String(contentsOf: root.appendingPathComponent("Sources/Parallax/Views/ContentView.swift"))
        XCTAssertTrue(content.contains("store.applicationRemovalRecoveryDetail ?? store.libraryRecoveryDetail"))
        let header = try String(contentsOf: root.appendingPathComponent("Sources/Parallax/Views/ApplicationHeaderView.swift"))
        XCTAssertTrue(header.contains(".disabled(store.isStorageRelocationRunning)"))
    }
}
