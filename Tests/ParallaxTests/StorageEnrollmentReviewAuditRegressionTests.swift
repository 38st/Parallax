import Darwin
import Foundation
import XCTest
@testable import Parallax

final class StorageEnrollmentReviewAuditRegressionTests: XCTestCase {
    func testCorruptSidecarIsAbsentAndRepairsOnEnrollment() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let store = f.coordinator.enrollmentStore
        let path = sidecar(f)
        try Data("broken".utf8).write(to: path)
        XCTAssertNil(try store.record(applicationStorageID: f.application.storageID))
        XCTAssertNoThrow(try store.enroll(applicationStorageID: f.application.storageID,
            configuredBaseRoot: f.source, canonicalBaseRoot: f.source))
        XCTAssertEqual(try store.record(applicationStorageID: f.application.storageID)?.baseRootPath, f.source.path)
    }

    func testUnsafeSidecarRepairsWithoutFollowingLink() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let target = f.root.appendingPathComponent("untouched")
        try Data("preserve".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: sidecar(f), withDestinationURL: target)
        XCTAssertNil(try f.coordinator.enrollmentStore.record(applicationStorageID: f.application.storageID))
        XCTAssertNoThrow(try f.coordinator.enrollmentStore.enroll(applicationStorageID: f.application.storageID,
            configuredBaseRoot: f.source, canonicalBaseRoot: f.source))
        XCTAssertEqual(try Data(contentsOf: target), Data("preserve".utf8))
        XCTAssertEqual(try f.coordinator.enrollmentStore.record(applicationStorageID: f.application.storageID)?.baseRootPath, f.source.path)
    }

    func testEnrollmentFailureAfterCommitDoesNotFailRelocation() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        let coordinator = try StorageRelocationCoordinator(applicationSupportURL: f.root, fileSystem: LocalFileSystem(),
            activityProvider: f.registry, availableCapacity: { _ in UInt64.max }, supportsPermissions: { _ in true },
            transactionBoundary: { boundary in
                if case .beforeSourceCleanup = boundary {
                    let lock = f.root.appendingPathComponent("Parallax/.storage-volumes.lock")
                    try? FileManager.default.removeItem(at: lock)
                    try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
                }
            })
        XCTAssertNoThrow(try coordinator.execute(preview, preparedCommit: f.prepared(preview), repository: f.repository))
        XCTAssertTrue(try coordinator.pendingRelocations().isEmpty)
        XCTAssertTrue(f.exists(preview.destination.applicationRoot.url))
    }

    func testEnrollmentFailureDoesNotBlockProfileOperation() throws {
        let helper = ProfileDataAuditRegressionTests()
        let f = try helper.fixture()
        defer { try? removeTestDirectory(at: f.root) }
        try helper.sourceData(f)
        try FileManager.default.createDirectory(at: f.root.appendingPathComponent("Parallax/.storage-volumes.lock"), withIntermediateDirectories: false)
        let outcome = try f.coordinator.execute(f.request, preparedCommit: f.prepared, repository: f.repository)
        XCTAssertEqual(outcome.dataMutation, .archivedManagedData)
    }

    func testNativeMountedVolumeMatchesEnrolledTemporaryRoot() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let store = f.coordinator.enrollmentStore
        try store.enroll(applicationStorageID: f.application.storageID, configuredBaseRoot: f.source, canonicalBaseRoot: f.source)
        let record = try XCTUnwrap(store.record(applicationStorageID: f.application.storageID))
        XCTAssertNotNil(record.volumeUUID)
        try FileManager.default.removeItem(at: f.source)
        XCTAssertNoThrow(try store.validateMissingRoot(f.source, applicationStorageID: f.application.storageID))
        let resolver = ManagedPathResolver(fileSystem: LocalFileSystem(), enrollmentStore: store)
        XCTAssertNoThrow(try resolver.resolve(baseRootURL: f.source, applicationStorageID: f.application.storageID, profileStorageID: UUID()))
    }

    func testForgettingEnrollmentRestoresLegacyBehaviorAndKeepsOtherApplications() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let store = try StorageVolumeEnrollmentStore(applicationSupportURL: f.root, isVolumeMounted: { _ in false })
        let otherID = UUID()
        for id in [f.application.storageID, otherID] {
            try store.recordVerifiedRoot(applicationStorageID: id, baseRoot: f.source,
                volumeUUID: "00000000-0000-0000-0000-000000000099")
        }
        let confirmed = try XCTUnwrap(store.record(applicationStorageID: f.application.storageID))
        try FileManager.default.removeItem(at: f.source)
        XCTAssertThrowsError(try store.validateMissingRoot(f.source, applicationStorageID: f.application.storageID))
        try store.forget(applicationStorageID: f.application.storageID, confirmedRecord: confirmed)
        XCTAssertNoThrow(try store.validateMissingRoot(f.source, applicationStorageID: f.application.storageID))
        XCTAssertNotNil(try store.record(applicationStorageID: otherID))
        XCTAssertFalse(f.exists(f.source))
    }

    func testForgetRefusesAnEnrollmentChangedSinceConfirmation() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let store = f.coordinator.enrollmentStore
        try store.recordVerifiedRoot(applicationStorageID: f.application.storageID, baseRoot: f.source,
            volumeUUID: "00000000-0000-0000-0000-000000000099")
        let confirmed = try XCTUnwrap(store.record(applicationStorageID: f.application.storageID))
        try store.recordVerifiedRoot(applicationStorageID: f.application.storageID, baseRoot: f.destination,
            volumeUUID: "00000000-0000-0000-0000-000000000001")
        XCTAssertThrowsError(try store.forget(applicationStorageID: f.application.storageID, confirmedRecord: confirmed))
        XCTAssertEqual(try store.record(applicationStorageID: f.application.storageID)?.baseRootPath, f.destination.path)
    }

    func testPruningFailureDoesNotReportCommittedProfileOperationAsFailed() throws {
        let helper = ProfileDataAuditRegressionTests()
        let f = try helper.fixture()
        defer { try? removeTestDirectory(at: f.root) }
        try helper.sourceData(f)
        let marker = f.coordinator.controlRootURL.appendingPathComponent(".parallax-pruning-" + UUID().uuidString.lowercased())
        let coordinator = try ProfileDataTransactionCoordinator(applicationSupportURL: f.root,
            activityRegistry: f.activityRegistry, transactionBoundary: { boundary in
                if boundary == .afterRecord(.writeReceipt) { try Data("invalid".utf8).write(to: marker) }
            })
        let outcome = try coordinator.execute(f.request, preparedCommit: f.prepared, repository: f.repository)
        XCTAssertEqual(outcome.dataMutation, .archivedManagedData)
        XCTAssertNil(outcome.operationFailure)
        try FileManager.default.removeItem(at: marker)
        _ = try f.repository.tryWithExclusiveAccess { access in
            try f.coordinator.performMaintenance(repository: f.repository, access: access)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.coordinator.controlRootURL.path).isEmpty)
    }

    private func sidecar(_ f: RelocationAuditFixture) -> URL {
        f.root.appendingPathComponent("Parallax/storage-volume-" + f.application.storageID.uuidString.lowercased() + ".json")
    }
}
