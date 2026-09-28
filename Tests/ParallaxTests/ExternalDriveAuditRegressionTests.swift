import Darwin
import Foundation
import XCTest
@testable import Parallax

final class ExternalDriveAuditRegressionTests: XCTestCase {
    func testCompletedRelocationMaintenancePreservesNewerEnrollment() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        try f.publishPlan(preview)
        let plan = try f.coordinator.loadControlPlan(preview.requestID)
        _ = try f.coordinator.writeControlReceipt(plan: plan, completion: .rolledBack)
        let nextRoot = f.root.appendingPathComponent("NewBase")
        try FileManager.default.createDirectory(at: nextRoot, withIntermediateDirectories: true)
        var application = f.application
        application.baseStoragePath = nextRoot.path
        _ = try f.repository.save([application], expectedVersion: f.version)
        try f.coordinator.enrollmentStore.enroll(applicationStorageID: application.storageID,
            configuredBaseRoot: nextRoot, canonicalBaseRoot: nextRoot)
        let expected = try f.coordinator.enrollmentStore.record(applicationStorageID: application.storageID)
        _ = try f.repository.tryWithExclusiveAccess { access in
            try f.coordinator.maintainControlState(repository: f.repository, access: access)
        }
        XCTAssertEqual(try f.coordinator.enrollmentStore.record(applicationStorageID: application.storageID), expected)
    }

    @MainActor
    func testLaunchAvailabilityCheckDoesNotOverwriteNewerEnrollment() async throws {
        let helper = ProfileDataAuditRegressionTests()
        let f = try helper.fixture()
        defer { try? removeTestDirectory(at: f.root) }
        let store = helper.store(f)
        let nextRoot = f.root.appendingPathComponent("NewBase")
        try FileManager.default.createDirectory(at: nextRoot, withIntermediateDirectories: true)
        var application = f.application
        application.baseStoragePath = nextRoot.path
        _ = try f.repository.save([application], expectedVersion: f.prepared.priorVersion)
        let enrollment = try StorageVolumeEnrollmentStore(applicationSupportURL: f.root)
        try enrollment.enroll(applicationStorageID: application.storageID,
            configuredBaseRoot: nextRoot, canonicalBaseRoot: nextRoot)
        let expected = try enrollment.record(applicationStorageID: application.storageID)
        try await store.validateStorageEnrollment(applicationStorageID: application.storageID,
            profileStorageID: f.request.identity.sourceProfileStorageID, configuredBaseRoot: f.root.path)
        XCTAssertEqual(try enrollment.record(applicationStorageID: application.storageID), expected)
    }

    func testProfileRootAcceptsReenumeratedDeviceOnSameVolume() throws {
        let helper = ProfileDataAuditRegressionTests()
        let f = try helper.fixture()
        defer { try? removeTestDirectory(at: f.root) }
        let binding = try f.coordinator.rootBinding(for: f.request.source.profileRoot.validationContext)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: f.coordinator.canonicalBytes(binding)) as? [String: Any])
        object["volumeID"] = binding.volumeID + 1
        object["identityVersion"] = 1
        object["volumeUUID"] = try ApplicationRemovalTransactionRootIdentity.read(SecureManagedFileSystem(rootURL: f.root)).volumeUUID
        let changed = try f.coordinator.decoder.decode(ProfileDataTransactionCoordinator.RootBinding.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNoThrow(try f.coordinator.secureFileSystem(for: changed))
    }

    func testMissingEnrolledRootOutsideVolumesIsUnavailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Enrollment-\(UUID())")
        defer { try? removeTestDirectory(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let base = root.appendingPathComponent("custom-mount/storage")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let id = UUID()
        let store = try StorageVolumeEnrollmentStore(applicationSupportURL: root,
            identitySource: { secure in
                StorageVolumeIdentity(device: UInt64(secure.rootIdentity.device), inode: UInt64(secure.rootIdentity.inode),
                    volumeUUID: "00000000-0000-0000-0000-000000000001")
            }, isVolumeMounted: { _ in false })
        try store.enroll(applicationStorageID: id, configuredBaseRoot: base, canonicalBaseRoot: base)
        let resolver = ManagedPathResolver(fileSystem: LocalFileSystem(), enrollmentStore: store)
        let paths = try resolver.resolve(baseRootURL: base, applicationStorageID: id, profileStorageID: UUID())
        try FileManager.default.removeItem(at: base)
        XCTAssertThrowsError(try resolver.resolve(baseRootURL: base, applicationStorageID: id, profileStorageID: UUID())) {
            XCTAssertEqual(($0 as? ManagedPathError)?.code, .baseRootUnavailable)
        }
        XCTAssertThrowsError(try resolver.revalidateForMutation(paths.profileRoot)) {
            XCTAssertEqual(($0 as? ManagedPathError)?.code, .baseRootUnavailable)
        }
        XCTAssertNoThrow(try resolver.resolve(baseRootURL: base, applicationStorageID: UUID(), profileStorageID: UUID()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent(".parallax").path))
    }

    func testMissingRootWithoutEnrollmentOrWithMountedVolumeKeepsLegacyBehavior() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Enrollment-\(UUID())")
        defer { try? removeTestDirectory(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let base = root.appendingPathComponent("custom-mount/storage")
        let id = UUID()
        let store = try StorageVolumeEnrollmentStore(applicationSupportURL: root,
            identitySource: { secure in StorageVolumeIdentity(device: UInt64(secure.rootIdentity.device),
                inode: UInt64(secure.rootIdentity.inode), volumeUUID: "00000000-0000-0000-0000-000000000001") },
            isVolumeMounted: { _ in true })
        let resolver = ManagedPathResolver(fileSystem: LocalFileSystem(), enrollmentStore: store)
        XCTAssertNoThrow(try resolver.resolve(baseRootURL: base, applicationStorageID: id, profileStorageID: UUID()))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try store.enroll(applicationStorageID: id, configuredBaseRoot: base, canonicalBaseRoot: base)
        try FileManager.default.removeItem(at: base)
        XCTAssertNoThrow(try resolver.resolve(baseRootURL: base, applicationStorageID: id, profileStorageID: UUID()))
    }

    func testChangedBaseRootDoesNotInheritOldVolumeEnrollment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Enrollment-\(UUID())")
        defer { try? removeTestDirectory(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()
        let store = try StorageVolumeEnrollmentStore(applicationSupportURL: root,
            identitySource: { secure in StorageVolumeIdentity(device: UInt64(secure.rootIdentity.device),
                inode: UInt64(secure.rootIdentity.inode), volumeUUID: "00000000-0000-0000-0000-000000000001") },
            isVolumeMounted: { _ in false })
        try store.enroll(applicationStorageID: id, configuredBaseRoot: root, canonicalBaseRoot: root)
        let resolver = ManagedPathResolver(fileSystem: LocalFileSystem(), enrollmentStore: store)
        XCTAssertNoThrow(try resolver.resolve(baseRootURL: root.appendingPathComponent("new-root"),
            applicationStorageID: id, profileStorageID: UUID()))
        XCTAssertNoThrow(try resolver.resolve(baseRootURL: root, applicationStorageID: id, profileStorageID: UUID()))
        let newRoot = root.appendingPathComponent("new-root")
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
        try store.enroll(applicationStorageID: id, configuredBaseRoot: newRoot, canonicalBaseRoot: newRoot)
        XCTAssertEqual(try store.record(applicationStorageID: id)?.baseRootPath, newRoot.path)
        try FileManager.default.removeItem(at: newRoot)
        XCTAssertThrowsError(try resolver.resolve(baseRootURL: newRoot, applicationStorageID: id, profileStorageID: UUID()))
    }

    func testEnrollmentLeavesLibraryBytesAndVersionUnchanged() throws {
        let helper = ProfileDataAuditRegressionTests()
        let f = try helper.fixture()
        defer { try? removeTestDirectory(at: f.root) }
        guard case .loaded(let before) = f.repository.load() else { return XCTFail("Missing fixture library") }
        let enrollment = try StorageVolumeEnrollmentStore(applicationSupportURL: f.root)
        try enrollment.enroll(applicationStorageID: f.application.storageID, configuredBaseRoot: f.root, canonicalBaseRoot: f.root)
        guard case .loaded(let after) = f.repository.load() else { return XCTFail("Enrollment blocked loading") }
        XCTAssertEqual(before.originalBytes, after.originalBytes)
        XCTAssertEqual(before.versionToken, after.versionToken)
        XCTAssertNotNil(try enrollment.record(applicationStorageID: f.application.storageID))
    }

    func testCompletedProfileTransactionsLeaveNoControlRecords() throws {
        for operation in [ProfileDataTransactionOperation.clear, .duplicate, .archive, .delete] {
            let helper = ProfileDataAuditRegressionTests()
            let f = try helper.fixture(operation)
            defer { try? removeTestDirectory(at: f.root) }
            try helper.sourceData(f)
            let outcome = try f.coordinator.execute(f.request, preparedCommit: f.prepared, repository: f.repository)
            XCTAssertNil(outcome.receiptURL)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.coordinator.controlRootURL.path).isEmpty)
        }
    }

    func testRelocationPlanRecordsDurableRootIdentity() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        let coordinator = try StorageRelocationCoordinator(applicationSupportURL: f.root, fileSystem: LocalFileSystem(),
            identitySource: { secure in StorageVolumeIdentity(device: UInt64(secure.rootIdentity.device),
                inode: UInt64(secure.rootIdentity.inode), volumeUUID: "00000000-0000-0000-0000-000000000001") },
            activityProvider: f.registry)
        let plan = try coordinator.makeControlPlan(preview: preview, preparedCommit: f.prepared(preview))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: coordinator.canonicalBytes(plan.unsigned)) as? [String: Any])
        let source = try XCTUnwrap(object["sourceRoot"] as? [String: Any])
        XCTAssertNotNil(source["volumeUUID"])
        XCTAssertNotNil(source["fileID"])
        XCTAssertNotNil(object["destinationRoot"])
    }

    func testCompletedRelocationLeavesNoControlRecords() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        let outcome = try f.coordinator.execute(preview, preparedCommit: f.prepared(preview), repository: f.repository)
        XCTAssertNil(outcome.receiptURL)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.coordinator.controlRootURL.path).isEmpty)
    }

    @MainActor
    func testPreviousCancelledHistoryMigratesOnceWithoutLosingEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryDowngrade-\(UUID())")
        defer { try? removeTestDirectory(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try LaunchHistoryStore(applicationSupportURL: root)
        let entry = LaunchHistoryEntry(requestID: UUID(), applicationID: UUID(), applicationStorageID: UUID(),
            profileID: UUID(), profileStorageID: UUID(), applicationName: "Synthetic", profileName: "Space",
            requestedAt: Date(timeIntervalSince1970: 100), state: .cancelled)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        object["state"] = "cancelled"
        object.removeValue(forKey: "wasCancelled")
        let file = root.appendingPathComponent("Parallax/launch-history.json")
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "entries": [object]]).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let migrated = try LaunchHistoryStore(applicationSupportURL: root)
        XCTAssertEqual(migrated.entries, [entry])
        XCTAssertNil(migrated.persistenceErrorMessage)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let entries = try XCTUnwrap(document["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.first?["state"] as? String, "closed")
        XCTAssertEqual(entries.first?["wasCancelled"] as? Bool, true)
        let identity = try LocalFileSystem().attributesOfItem(at: file).identity
        _ = try LaunchHistoryStore(applicationSupportURL: root)
        XCTAssertEqual(try LocalFileSystem().attributesOfItem(at: file).identity, identity)
    }

    func testCancelledHistoryUsesLegacyStateAndStillRoundTrips() throws {
        let entry = LaunchHistoryEntry(requestID: UUID(), applicationID: UUID(), applicationStorageID: UUID(),
            profileID: UUID(), profileStorageID: UUID(), applicationName: "Synthetic", profileName: "Space",
            requestedAt: Date(timeIntervalSince1970: 100), state: .cancelled)
        let data = try JSONEncoder().encode(entry)
        struct LegacyEntry: Decodable {
            enum State: String, Decodable { case opening, running, closed, failed }
            let state: State
        }
        XCTAssertEqual(try JSONDecoder().decode(LegacyEntry.self, from: data).state, .closed)
        XCTAssertEqual(try JSONDecoder().decode(LaunchHistoryEntry.self, from: data).state, .cancelled)
        var previous = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        previous["state"] = "cancelled"
        previous.removeValue(forKey: "wasCancelled")
        XCTAssertEqual(try JSONDecoder().decode(LaunchHistoryEntry.self,
            from: JSONSerialization.data(withJSONObject: previous)).state, .cancelled)
    }
}
