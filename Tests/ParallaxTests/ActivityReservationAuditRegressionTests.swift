import Foundation
import XCTest

@testable import Parallax

final class ActivityReservationAuditRegressionTests: XCTestCase {
    private func identity() -> ProfileActivityIdentity {
        ProfileActivityIdentity(
            applicationID: UUID(), applicationStorageID: UUID(), profileID: UUID(),
            profileStorageID: UUID())
    }

    func testDataReservationBlocksPeerLaunchIncludingExpertOverrideUntilReleased() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = TestWorkspaceProcessState()
        let owner = try ProfileActivityRegistry(
            applicationSupportURL: root, processInspector: state)
        let peer = try ProfileActivityRegistry(applicationSupportURL: root, processInspector: state)
        let target = identity()
        let lease = try owner.acquireDataOperationLease(identities: [target])
        for policy in [
            ConcurrentProfileLaunchPolicy.deny,
            .expertOverride(.init(acknowledgesProfileDataCorruptionRisk: true)),
        ] {
            XCTAssertThrowsError(
                try peer.acquireLaunchLease(
                    identity: target, requestID: UUID(), concurrentLaunchPolicy: policy)
            ) { error in
                guard case ProfileActivityRegistryError.storageReservedForDataOperation = error
                else { return XCTFail("Expected reservation message: \(error)") }
            }
        }
        XCTAssertFalse(peer.isActive(identity: target))
        lease.release()
        let requestID = UUID()
        let opened = try peer.acquireLaunchLease(identity: target, requestID: requestID)
        try peer.completeDurableLaunch(requestID: requestID, completion: .failed)
        opened.release()
        XCTAssertFalse(owner.isActive(identity: target))
    }

    func testPartialReservationFailureReleasesEveryAcquiredIdentity() throws {
        let registry = ProfileActivityRegistry()
        let occupied = identity()
        let available = identity()
        let launch = try registry.acquireLaunchLease(identity: occupied, requestID: UUID())
        defer { launch.release() }
        XCTAssertThrowsError(
            try registry.acquireDataOperationLease(identities: [available, occupied]))
        XCTAssertFalse(registry.isActive(identity: available))
        XCTAssertTrue(registry.isActive(identity: occupied))
    }

    func testReservationDeinitReleasesMemoryLease() throws {
        let registry = ProfileActivityRegistry()
        let target = identity()
        var lease: ProfileActivityReservation? = try registry.acquireDataOperationLease(
            identities: [
            target
        ])
        XCTAssertNotNil(lease)
        XCTAssertFalse(registry.isActive(identity: target))
        XCTAssertTrue(
            registry.isStorageActive(
                applicationStorageID: target.applicationStorageID,
                profileStorageID: target.profileStorageID))
        lease = nil
        XCTAssertFalse(registry.isActive(identity: target))
    }
}
