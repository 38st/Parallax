import Darwin
import Foundation
import XCTest
@testable import Parallax

final class ForgetStorageVolumeAuditRegressionTests: XCTestCase {
    @MainActor
    func testConfirmedForgetLeavesLibraryBytesAndManagedDataUntouched() async throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let store = LibraryStore(repository: f.repository, storageRelocationCoordinator: f.coordinator,
            profileActivityRegistry: f.registry)
        try f.coordinator.enrollmentStore.recordVerifiedRoot(applicationStorageID: f.application.storageID, baseRoot: f.source,
            volumeUUID: "00000000-0000-0000-0000-000000000099")
        let preserved = f.root.appendingPathComponent("Disconnected")
        try FileManager.default.moveItem(at: f.source, to: preserved)
        let pending = await store.unavailableStorageRecovery(applicationID: f.application.id)
        let confirmed = try XCTUnwrap(pending)
        guard case .loaded(let before) = f.repository.load() else { return XCTFail("Library unavailable") }
        let succeeded = await store.forgetStorageVolume(confirmed)
        XCTAssertTrue(succeeded)
        guard case .loaded(let after) = f.repository.load() else { return XCTFail("Library unavailable") }
        XCTAssertEqual(before.originalBytes, after.originalBytes)
        XCTAssertEqual(before.versionToken, after.versionToken)
        XCTAssertFalse(f.exists(f.source))
        XCTAssertTrue(f.exists(preserved.appendingPathComponent(".parallax/Applications/" + f.application.storageID.uuidString.lowercased() + "/data")))
        XCTAssertNoThrow(try store.pathResolver.resolveApplication(configuredBaseRoot: f.source.path,
            applicationStorageID: f.application.storageID))
    }

    @MainActor
    func testForgetRefusesChangedLibraryConfiguration() async throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let store = LibraryStore(repository: f.repository, storageRelocationCoordinator: f.coordinator,
            profileActivityRegistry: f.registry)
        try f.coordinator.enrollmentStore.recordVerifiedRoot(applicationStorageID: f.application.storageID, baseRoot: f.source,
            volumeUUID: "00000000-0000-0000-0000-000000000099")
        try FileManager.default.removeItem(at: f.source)
        let pending = await store.unavailableStorageRecovery(applicationID: f.application.id)
        let confirmed = try XCTUnwrap(pending)
        var application = f.application
        application.baseStoragePath = f.destination.path
        _ = try f.repository.save([application], expectedVersion: f.version)
        let succeeded = await store.forgetStorageVolume(confirmed)
        XCTAssertFalse(succeeded)
        XCTAssertNotNil(try f.coordinator.enrollmentStore.record(applicationStorageID: application.storageID))
    }

    func testProductionEnrollmentDoesNotRepairUnsafeContainerPermissions() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let container = f.root.appendingPathComponent("Parallax")
        XCTAssertEqual(chmod(container.path, 0o755), 0)
        let store = try StorageVolumeEnrollmentStore(applicationSupportURL: f.root)
        XCTAssertThrowsError(try store.enroll(applicationStorageID: f.application.storageID,
            configuredBaseRoot: f.source, canonicalBaseRoot: f.source))
        var status = stat()
        XCTAssertEqual(lstat(container.path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o7777, 0o755)
    }

    func testSharedProductionEnrollmentStoreIsReused() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let first = try StorageVolumeEnrollmentStore.shared(applicationSupportURL: f.root)
        let second = try StorageVolumeEnrollmentStore.shared(applicationSupportURL: f.root)
        XCTAssertTrue(first === second)
    }
}
