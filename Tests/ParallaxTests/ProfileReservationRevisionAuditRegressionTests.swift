import Darwin
import Foundation
import XCTest
@testable import Parallax

final class ProfileReservationRevisionAuditRegressionTests: XCTestCase {
    func override(for identity: ProfileActivityIdentity) throws -> DestructiveActionExecutionAuthorization {
        let request = DestructiveActionRequest(requestID: UUID(), sceneID: UUID(), operation: .clearProfileData,
            applicationID: identity.applicationID, applicationStorageID: identity.applicationStorageID,
            profileID: identity.profileID, profileStorageID: identity.profileStorageID,
            applicationName: "Synthetic", profileName: "Synthetic",
            path: .init(canonicalURL: URL(fileURLWithPath: "/synthetic"), fileIdentity: nil),
            configurationRevision: 0, libraryVersion: .missing)
        return try request.authorizeExecution(currentTarget: DestructiveActionCurrentTarget(
            applicationID: identity.applicationID, applicationStorageID: identity.applicationStorageID,
            profileID: identity.profileID, profileStorageID: identity.profileStorageID, path: request.path,
            configurationRevision: 0, libraryVersion: .missing), activity: .init(identity: identity, state: .active),
            expertOverride: request.makeExpertOverrideAuthorization(acknowledging: .profileDataCorruptionAndProcessInstability))
    }

    func testDestructiveOverrideAllowsLiveLaunchButNeverAnotherReservation() throws {
        for durable in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let registry = try durable ? ProfileActivityRegistry(applicationSupportURL: root,
                refreshScheduler: SupervisorTestScheduler()) : ProfileActivityRegistry()
            let identity = ProfileActivityIdentity(applicationID: UUID(), applicationStorageID: UUID(), profileID: UUID(), profileStorageID: UUID())
            let launchID = UUID()
            let launch = try registry.acquireLaunchLease(identity: identity, requestID: launchID)
            defer { try? registry.completeDurableLaunch(requestID: launchID, completion: .terminated); launch.release() }
            let policy = DataOperationActivityPolicy.destructiveExpertOverride(try override(for: identity))
            let reservation = try registry.acquireDataOperationLease(identities: [identity], activityPolicy: policy)
            defer { reservation.release() }
            if durable {
                let peer = try DurableLaunchActivityStore(applicationSupportURL: root)
                guard case .live(let owner) = SystemProcessIdentityInspector().inspect(processIdentifier: getpid()) else { return XCTFail() }
                XCTAssertThrowsError(try peer.createRequest(requestID: UUID(), identity: identity, ownerProcess: owner,
                    allowsConcurrentProfile: true, isDataOperation: true))
            }
            XCTAssertThrowsError(try registry.acquireDataOperationLease(identities: [identity], activityPolicy: policy)) {
                guard case ProfileActivityRegistryError.storageReservedForDataOperation = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
            XCTAssertThrowsError(try registry.acquireLaunchLease(identity: identity, requestID: UUID(),
                concurrentLaunchPolicy: .expertOverride(.init(acknowledgesProfileDataCorruptionRisk: true)))) {
                guard case ProfileActivityRegistryError.storageReservedForDataOperation = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
        }
    }

    @MainActor
    func testReservationReleaseWhileActivityLockIsContendedClearsMemory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let completions = SupervisorTestScheduler()
        let registry = try ProfileActivityRegistry(applicationSupportURL: root, refreshScheduler: SupervisorTestScheduler(), completionScheduler: completions)
        let identity = ProfileActivityIdentity(applicationID: UUID(), applicationStorageID: UUID(), profileID: UUID(), profileStorageID: UUID())
        let reservation = try registry.acquireDataOperationLease(identities: [identity])
        let descriptor = open(root.appendingPathComponent("Parallax/ActiveLaunches/.profile-acquisition.lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        reservation.release()
        XCTAssertFalse(registry.isStorageReserved(applicationStorageID: identity.applicationStorageID, profileStorageID: identity.profileStorageID))
        XCTAssertEqual(completions.pendingCount, 1)
        XCTAssertThrowsError(try registry.acquireDataOperationLease(identities: [identity]))
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        let blockedPeer = try ProfileActivityRegistry(applicationSupportURL: root, refreshScheduler: SupervisorTestScheduler())
        XCTAssertThrowsError(try blockedPeer.acquireDataOperationLease(identities: [identity]))
        let completed = expectation(description: "Durable release retried")
        DispatchQueue.global().async { completions.runNext(); completed.fulfill() }
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(completions.pendingCount, 0)
        XCTAssertTrue(try DurableLaunchActivityStore(applicationSupportURL: root).artifacts().isEmpty)
        let peer = try ProfileActivityRegistry(applicationSupportURL: root, refreshScheduler: SupervisorTestScheduler())
        let next = try peer.acquireDataOperationLease(identities: [identity])
        next.release()
    }
}
