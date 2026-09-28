import Foundation
import XCTest
@testable import Parallax

@MainActor
final class StorageVolumeRecoveryPresentationTests: XCTestCase {
    func testForgetRequiresConfirmationAndCancelPreservesEnrollment() async throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let (store, enrollment) = try makeStore(f)
        try enroll(f, in: enrollment)
        let preserved = f.root.appendingPathComponent("Disconnected")
        try FileManager.default.moveItem(at: f.source, to: preserved)
        let presentation = StorageVolumeRecoveryPresentation()
        await presentation.refresh(store: store, applicationID: f.application.id)
        let request = try XCTUnwrap(presentation.recovery)
        XCTAssertNil(presentation.confirm(store: store))
        presentation.requestConfirmation()
        XCTAssertEqual(presentation.pendingConfirmation, request)
        XCTAssertTrue(request.confirmationMessage.contains(f.application.displayName))
        XCTAssertTrue(request.confirmationMessage.contains(f.source.path))
        XCTAssertNotNil(try enrollment.record(applicationStorageID: f.application.storageID))
        presentation.cancelConfirmation()
        XCTAssertNil(presentation.pendingConfirmation)
        XCTAssertNil(presentation.confirm(store: store))
        XCTAssertNotNil(try enrollment.record(applicationStorageID: f.application.storageID))

        let before = try Data(contentsOf: f.root.appendingPathComponent("Parallax/library.json"))
        presentation.requestConfirmation()
        let operation = try XCTUnwrap(presentation.confirm(store: store))
        XCTAssertNil(presentation.pendingConfirmation)
        XCTAssertNil(presentation.confirm(store: store))
        let succeeded = await operation.value
        XCTAssertTrue(succeeded)
        XCTAssertNil(presentation.recovery)
        XCTAssertNil(try enrollment.record(applicationStorageID: f.application.storageID))
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Parallax/library.json")), before)
        XCTAssertFalse(f.exists(f.source))
        let dataPath = ".parallax/Applications/" + f.application.storageID.uuidString.lowercased() + "/data"
        XCTAssertEqual(try Data(contentsOf: preserved.appendingPathComponent(dataPath)), Data("original".utf8))
        XCTAssertNil(store.selectedApplicationID)
        XCTAssertNil(store.selectedProfileID)
    }

    func testOfferRequiresMissingRootAndUnmountedEnrolledVolume() async throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let (store, enrollment) = try makeStore(f)
        let presentation = StorageVolumeRecoveryPresentation()
        try enroll(f, in: enrollment)
        await presentation.refresh(store: store, applicationID: f.application.id)
        XCTAssertNil(presentation.recovery, "An existing root must not offer Forget")
        try FileManager.default.removeItem(at: f.source)
        await presentation.refresh(store: store, applicationID: f.application.id)
        XCTAssertNotNil(presentation.recovery)

        let (mountedStore, _) = try makeStore(f, isMounted: true)
        await presentation.refresh(store: mountedStore, applicationID: f.application.id)
        XCTAssertNil(presentation.recovery, "A missing folder on a mounted volume must not offer Forget")
        let record = try XCTUnwrap(enrollment.record(applicationStorageID: f.application.storageID))
        try enrollment.forget(applicationStorageID: f.application.storageID, confirmedRecord: record)
        await presentation.refresh(store: store, applicationID: f.application.id)
        XCTAssertNil(presentation.recovery, "An unenrolled missing root must not offer Forget")
    }

    func testReconnectedRootInvalidatesConfirmationWithoutForgetting() async throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let (store, enrollment) = try makeStore(f)
        try enroll(f, in: enrollment)
        let preserved = f.root.appendingPathComponent("Disconnected")
        try FileManager.default.moveItem(at: f.source, to: preserved)
        let presentation = StorageVolumeRecoveryPresentation()
        await presentation.refresh(store: store, applicationID: f.application.id)
        presentation.requestConfirmation()
        try FileManager.default.moveItem(at: preserved, to: f.source)
        let operation = try XCTUnwrap(presentation.confirm(store: store))
        let succeeded = await operation.value
        XCTAssertFalse(succeeded)
        XCTAssertNotNil(try enrollment.record(applicationStorageID: f.application.storageID))
        XCTAssertNil(presentation.recovery)
    }

    func testApplicationChangeDismissesConfirmation() async throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let (store, enrollment) = try makeStore(f)
        try enroll(f, in: enrollment)
        try FileManager.default.removeItem(at: f.source)
        let presentation = StorageVolumeRecoveryPresentation()
        await presentation.refresh(store: store, applicationID: f.application.id)
        presentation.requestConfirmation()
        XCTAssertNotNil(presentation.pendingConfirmation)
        await presentation.refresh(store: store, applicationID: UUID())
        XCTAssertNil(presentation.pendingConfirmation)
        XCTAssertNil(presentation.recovery)
        XCTAssertNil(presentation.confirm(store: store))
        XCTAssertNotNil(try enrollment.record(applicationStorageID: f.application.storageID))
    }

    func testChangedEnrollmentRejectsStaleConfirmation() async throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let (store, enrollment) = try makeStore(f)
        try enroll(f, in: enrollment)
        try FileManager.default.removeItem(at: f.source)
        let presentation = StorageVolumeRecoveryPresentation()
        await presentation.refresh(store: store, applicationID: f.application.id)
        presentation.requestConfirmation()
        let replacementUUID = "00000000-0000-0000-0000-000000000098"
        try enrollment.recordVerifiedRoot(applicationStorageID: f.application.storageID,
            baseRoot: f.source, volumeUUID: replacementUUID)
        let operation = try XCTUnwrap(presentation.confirm(store: store))
        let succeeded = await operation.value
        XCTAssertFalse(succeeded)
        XCTAssertEqual(try enrollment.record(applicationStorageID: f.application.storageID)?.volumeUUID, replacementUUID)
    }

    private func makeStore(
        _ f: RelocationAuditFixture,
        isMounted: Bool = false
    ) throws -> (LibraryStore, StorageVolumeEnrollmentStore) {
        let enrollment = try StorageVolumeEnrollmentStore(
            applicationSupportURL: f.root,
            isVolumeMounted: { _ in isMounted }
        )
        let transactions = try ProfileDataTransactionCoordinator(
            applicationSupportURL: f.root,
            enrollmentStore: enrollment
        )
        let store = LibraryStore(
            repository: f.repository,
            profileDataTransactions: transactions,
            profileActivityRegistry: f.registry
        )
        return (store, enrollment)
    }

    private func enroll(_ f: RelocationAuditFixture, in enrollment: StorageVolumeEnrollmentStore) throws {
        try enrollment.recordVerifiedRoot(applicationStorageID: f.application.storageID,
            baseRoot: f.source, volumeUUID: "00000000-0000-0000-0000-000000000099")
    }
}
