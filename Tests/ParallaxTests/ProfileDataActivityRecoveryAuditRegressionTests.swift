import Foundation
import XCTest
@testable import Parallax

extension ProfileDataAuditRegressionTests {
    func testProfileExecutionAndRecoveryShareInjectedRegistry() throws {
        let f = try fixture()
        try sourceData(f)
        let identity = try XCTUnwrap(f.coordinator.activityIdentities(f.request.identity).first)
        let lease = try f.activityRegistry.acquire(identity: identity, requestID: UUID())
        defer { lease.release() }
        XCTAssertThrowsError(try f.coordinator.execute(f.request, preparedCommit: f.prepared, repository: f.repository)) { error in
            guard case ProfileActivityRegistryError.profileAlreadyActive = error else {
                return XCTFail("Expected the in-memory launch to block execution, got \(error)")
            }
        }
        XCTAssertTrue(try f.coordinator.pendingTransactions().isEmpty)
        try f.coordinator.publishPlan(f.coordinator.preparePlan(request: f.request, preparedCommit: f.prepared))
        XCTAssertThrowsError(try recoverRevisionFixture(f)) { error in
            guard case ProfileActivityRegistryError.profileAlreadyActive = error else {
                return XCTFail("Expected the in-memory launch to block recovery, got \(error)")
            }
        }
        XCTAssertEqual(try f.coordinator.pendingTransactions().count, 1)

        lease.release()
        try recoverRevisionFixture(f)
        XCTAssertTrue(try f.coordinator.pendingTransactions().isEmpty)
        XCTAssertEqual(try String(contentsOf: f.request.source.profileRoot.url.appendingPathComponent("sentinel")), "source")
    }

    @MainActor
    func testProfileRecoveryUsesStoreRegistryForInMemoryLease() throws {
        for injectCoordinator in [false, true] {
            let f = try fixture()
            try sourceData(f)
            let log = try f.coordinator.preparePlan(request: f.request, preparedCommit: f.prepared)
            try f.coordinator.publishPlan(log)
            let registry = ProfileActivityRegistry()
            let lease = try registry.acquireDataOperationLease(
                identities: f.coordinator.activityIdentities(f.request.identity))
            defer { lease.release() }
            let store = LibraryStore(repository: f.repository,
                profileDataTransactions: injectCoordinator ? f.coordinator : nil,
                profileActivityRegistry: registry, settings: AppSettings())
            XCTAssertTrue(store.isLibraryOperationInProgress)
            XCTAssertEqual(try f.coordinator.pendingTransactions().count, 1)
            XCTAssertEqual(try String(contentsOf: f.request.source.profileRoot.url.appendingPathComponent("sentinel")), "source")

            lease.release()
            store.retryBusyLibraryLoad()
            XCTAssertFalse(store.isLibraryOperationInProgress)
            XCTAssertTrue(try f.coordinator.pendingTransactions().isEmpty)
        }
    }
}
