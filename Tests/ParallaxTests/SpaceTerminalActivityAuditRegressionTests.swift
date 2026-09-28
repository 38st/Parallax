import Darwin
import Foundation
import XCTest
@testable import Parallax

final class SpaceTerminalActivityAuditRegressionTests: XCTestCase {
    func testHandoffCoexistsWithLaunchButExcludesDataOperationUntilReleased() throws {
        let registry = ProfileActivityRegistry()
        let identity = makeIdentity()
        let launch = try registry.acquireLaunchLease(identity: identity, requestID: UUID())
        defer { launch.release() }
        let handoff = try registry.acquireTerminalHandoffLease(identity: identity)
        defer { handoff.release() }
        XCTAssertEqual(registry.activeLeaseCount(identity: identity), 2)
        launch.release()
        XCTAssertThrowsError(try registry.acquireDataOperationLease(identities: [identity])) {
            guard case ProfileActivityRegistryError.storageReservedForDataOperation = $0 else {
                return XCTFail("Expected a handoff reservation, got \($0)")
            }
        }
        handoff.release()
        let dataOperation = try registry.acquireDataOperationLease(identities: [identity])
        dataOperation.release()
        XCTAssertEqual(registry.activeLeaseCount(identity: identity), 0)
    }

    func testDataOperationReservationRefusesHandoff() throws {
        let registry = ProfileActivityRegistry()
        let identity = makeIdentity()
        let dataOperation = try registry.acquireDataOperationLease(identities: [identity])
        defer { dataOperation.release() }
        XCTAssertThrowsError(try registry.acquireTerminalHandoffLease(identity: identity)) {
            guard case ProfileActivityRegistryError.storageReservedForDataOperation = $0 else {
                return XCTFail("Expected a data-operation reservation, got \($0)")
            }
        }
    }

    func testHandoffUsesExistingDurableReservationFormatAcrossRegistries() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("Parallax-Terminal-Activity-\(UUID())")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? removeTestDirectory(at: support) }
        let inspector = TerminalFixtureProcessInspector()
        let first = try ProfileActivityRegistry(applicationSupportURL: support,
            refreshScheduler: SupervisorTestScheduler(), processInspector: inspector,
            completionScheduler: SupervisorTestScheduler())
        let second = try ProfileActivityRegistry(applicationSupportURL: support,
            refreshScheduler: SupervisorTestScheduler(), processInspector: inspector,
            completionScheduler: SupervisorTestScheduler())
        let identity = makeIdentity()
        let launchID = UUID()
        let launch = try first.acquireLaunchLease(identity: identity, requestID: launchID)
        defer { launch.release() }
        let handoff = try second.acquireTerminalHandoffLease(identity: identity)
        defer { handoff.release() }
        launch.release()
        try first.completeDurableLaunch(requestID: launchID, completion: .terminated)
        _ = try first.reconcileDurableActivity()
        XCTAssertTrue(first.isStorageReserved(applicationStorageID: identity.applicationStorageID,
            profileStorageID: identity.profileStorageID))
        XCTAssertThrowsError(try first.acquireDataOperationLease(identities: [identity])) {
            guard case ProfileActivityRegistryError.storageReservedForDataOperation = $0 else {
                return XCTFail("Expected the other registry's reservation, got \($0)")
            }
        }
        handoff.release()
        let operation = try first.acquireDataOperationLease(identities: [identity])
        operation.release()
        _ = try second.reconcileDurableActivity()
        XCTAssertFalse(second.isStorageReserved(applicationStorageID: identity.applicationStorageID,
            profileStorageID: identity.profileStorageID))
    }

    private func makeIdentity() -> ProfileActivityIdentity {
        .init(applicationID: UUID(), applicationStorageID: UUID(), profileID: UUID(), profileStorageID: UUID())
    }
}

private struct TerminalFixtureProcessInspector: ProcessIdentityInspecting {
    func inspect(processIdentifier: pid_t) -> ProcessIdentityInspection {
        guard processIdentifier == getpid() else { return .dead }
        return .live(ProcessStartIdentity(processIdentifier: processIdentifier,
            startTimeSeconds: 100, startTimeMicroseconds: 1))
    }
}
