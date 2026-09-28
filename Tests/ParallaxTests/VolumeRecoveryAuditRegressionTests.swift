import Darwin
import Foundation
import XCTest
@testable import Parallax

final class VolumeRecoveryAuditRegressionTests: XCTestCase {
    private enum Interruption: Error { case stopped }
    private static let volume = "00000000-0000-0000-0000-000000000001"

    func testCommittedRecoveryAllowsUnavailableSourceRoot() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        try f.publishPlan(preview)
        try f.publishCopy(preview)
        _ = try f.repository.save([preview.relocatedApplication], expectedVersion: f.version)
        try FileManager.default.removeItem(at: f.source)
        guard case .committed(let outcome) = try f.recover(preview) else { return XCTFail("Expected commit") }
        XCTAssertEqual(outcome.leftoverSourcePaths, [preview.source.applicationRoot.url.path])
        XCTAssertTrue(f.exists(preview.destination.applicationRoot.url))
        XCTAssertTrue(try f.coordinator.pendingRelocations().isEmpty)
    }

    func testProfileRecoveryAcceptsDeviceChangeAndUUIDUnavailableFallback() throws {
        let identities: [(String?, String?)] = [(Self.volume, Self.volume), (Self.volume, nil)]
        for (writtenUUID, readUUID) in identities {
            let helper = ProfileDataAuditRegressionTests()
            let f = try helper.fixture()
            defer { try? removeTestDirectory(at: f.root) }
            try helper.sourceData(f)
            let writer = try ProfileDataTransactionCoordinator(applicationSupportURL: f.root,
                activityRegistry: f.activityRegistry, identitySource: { secure in
                    StorageVolumeIdentity(device: UInt64(secure.rootIdentity.device) + 1,
                        inode: UInt64(secure.rootIdentity.inode), volumeUUID: writtenUUID)
                }, transactionBoundary: { boundary in
                    if boundary == .afterEffectBeforeRecord(.moveToStaging) { throw Interruption.stopped }
                })
            XCTAssertThrowsError(try writer.execute(f.request, preparedCommit: f.prepared,
                repository: f.repository, recoverOnFailure: false))
            let reader = try ProfileDataTransactionCoordinator(applicationSupportURL: f.root,
                activityRegistry: f.activityRegistry, identitySource: { secure in
                    StorageVolumeIdentity(device: UInt64(secure.rootIdentity.device) + 2,
                        inode: UInt64(secure.rootIdentity.inode), volumeUUID: readUUID)
                })
            let result = try f.repository.tryWithExclusiveAccess { access in
                try reader.recover(transactionID: f.request.transactionID, repository: f.repository, access: access)
            }
            guard case .acquired(let outcome) = result else { return XCTFail("Lock busy") }
            XCTAssertEqual(outcome.dataMutation, .rolledBack)
            XCTAssertEqual(try Data(contentsOf: f.request.source.profileRoot.url.appendingPathComponent("sentinel")), Data("source".utf8))
        }
    }

    func testProfileRootRefusesOtherVolumeOrChangedInodeAndLegacyStillChecksDevice() throws {
        let helper = ProfileDataAuditRegressionTests()
        let f = try helper.fixture()
        defer { try? removeTestDirectory(at: f.root) }
        let disk = try StorageVolumeIdentity.read(SecureManagedFileSystem(rootURL: f.root))
        let actual = StorageVolumeIdentity(device: disk.device, inode: disk.inode, volumeUUID: Self.volume)
        let reader = try ProfileDataTransactionCoordinator(applicationSupportURL: f.root, identitySource: { _ in actual })
        let differentVolume = StorageTransactionRootBinding(path: f.root.path, volumeID: actual.device, fileID: actual.inode,
            identityVersion: 1, volumeUUID: "00000000-0000-0000-0000-000000000099")
        XCTAssertThrowsError(try reader.secureFileSystem(for: differentVolume))
        let differentInode = StorageTransactionRootBinding(path: f.root.path, volumeID: actual.device, fileID: actual.inode + 1,
            identityVersion: 1, volumeUUID: actual.volumeUUID)
        XCTAssertThrowsError(try reader.secureFileSystem(for: differentInode))
        let legacy = StorageTransactionRootBinding(path: f.root.path, volumeID: actual.device + 1, fileID: actual.inode)
        XCTAssertThrowsError(try reader.secureFileSystem(for: legacy))
        let bytes = try JSONEncoder().encode(legacy)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNil(object["identityVersion"])
        XCTAssertNil(object["volumeUUID"])
    }

    func testDeletePayloadOwnershipAcceptsChangedDeviceButRejectsChangedInode() throws {
        let helper = ProfileDataAuditRegressionTests()
        let f = try helper.fixture(.delete) { boundary in
            if boundary == .beforeEffect(.removeDeletedPayload) { throw Interruption.stopped }
        }
        defer { try? removeTestDirectory(at: f.root) }
        try helper.sourceData(f)
        XCTAssertThrowsError(try f.coordinator.execute(f.request, preparedCommit: f.prepared,
            repository: f.repository, recoverOnFailure: false))
        let original = try f.coordinator.loadLog(transactionID: f.request.transactionID)
        let secure = try f.coordinator.secureFileSystem(for: original.plan.hostRoot)
        for changedInode in [false, true] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original.planBytes) as? [String: Any])
            var snapshot = try XCTUnwrap(object["sourceSnapshot"] as? [String: Any])
            var identity = try XCTUnwrap(snapshot["identity"] as? [String: Any])
            identity["volumeID"] = try XCTUnwrap(identity["volumeID"] as? UInt64) + 1
            if changedInode { identity["fileID"] = try XCTUnwrap(identity["fileID"] as? UInt64) + 1 }
            snapshot["identity"] = identity
            object["sourceSnapshot"] = snapshot
            let plan = try f.coordinator.decoder.decode(ProfileDataTransactionCoordinator.Plan.self,
                from: JSONSerialization.data(withJSONObject: object))
            // Exercise the ownership predicate with a simulated saved device;
            // the real marker and its publication proof remain unchanged.
            let log = ProfileDataTransactionCoordinator.TransactionLog(plan: plan,
                planBytes: original.planBytes, planHash: original.planHash, records: original.records)
            if changedInode {
                XCTAssertThrowsError(try f.coordinator.requireRemovalOwner(log: log, fileSystem: secure,
                    container: plan.payloadPath.value, effect: .removeDeletedPayload))
            } else {
                XCTAssertNoThrow(try f.coordinator.requireRemovalOwner(log: log, fileSystem: secure,
                    container: plan.payloadPath.value, effect: .removeDeletedPayload))
            }
        }
    }

    func testRelocationRecoveryRebasesTreeDeviceOnlyForNewPlans() throws {
        for legacy in [false, true] {
            let f = try RelocationAuditFixture()
            defer { f.remove() }
            let preview = try f.preview()
            let plan = try f.coordinator.makeControlPlan(preview: preview, preparedCommit: f.prepared(preview))
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: f.coordinator.canonicalBytes(plan.unsigned)) as? [String: Any])
            var snapshot = try XCTUnwrap(object["sourceApplicationSnapshot"] as? [String: Any])
            var identity = try XCTUnwrap(snapshot["identity"] as? [String: Any])
            identity["volumeID"] = try XCTUnwrap(identity["volumeID"] as? UInt64) + 1
            snapshot["identity"] = identity
            object["sourceApplicationSnapshot"] = snapshot
            if legacy {
                object["version"] = 2
                object.removeValue(forKey: "sourceRoot")
                object.removeValue(forKey: "destinationRoot")
            }
            let unsigned = try f.coordinator.decoder.decode(StorageRelocationControlPlan.Unsigned.self,
                from: JSONSerialization.data(withJSONObject: object))
            let changed = StorageRelocationControlPlan(unsigned: unsigned,
                planSHA256: LibraryPersistence.sha256(try f.coordinator.canonicalBytes(unsigned)))
            try f.coordinator.writeControlPlan(changed)
            try f.publishCopy(preview)
            if legacy {
                XCTAssertThrowsError(try f.recover(preview))
                XCTAssertTrue(f.exists(preview.destination.applicationRoot.url))
            } else {
                XCTAssertEqual(try f.recover(preview), .rolledBack)
                XCTAssertFalse(f.exists(preview.destination.applicationRoot.url))
            }
            XCTAssertTrue(f.exists(preview.source.applicationRoot.url))
        }
    }

    func testRelocationRootAcceptsReenumerationAndUUIDUnavailableFallback() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let disk = try StorageVolumeIdentity.read(SecureManagedFileSystem(rootURL: f.source))
        for readableUUID in [Self.volume, nil] {
            let reader = try StorageRelocationCoordinator(applicationSupportURL: f.root, fileSystem: LocalFileSystem(),
                identitySource: { _ in StorageVolumeIdentity(device: disk.device + 2, inode: disk.inode, volumeUUID: readableUUID) },
                activityProvider: f.registry)
            let binding = StorageTransactionRootBinding(path: f.source.path, volumeID: disk.device + 1,
                fileID: disk.inode, identityVersion: 1, volumeUUID: Self.volume)
            XCTAssertNoThrow(try reader.validateRecoveryRoot(binding, basePath: f.source.path))
        }
    }

    func testRelocationRefusesDifferentDestinationVolume() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        let writer = try StorageRelocationCoordinator(applicationSupportURL: f.root, fileSystem: LocalFileSystem(),
            identitySource: { secure in
                StorageVolumeIdentity(device: UInt64(secure.rootIdentity.device), inode: UInt64(secure.rootIdentity.inode),
                    volumeUUID: Self.volume)
            }, activityProvider: f.registry)
        try writer.writeControlPlan(writer.makeControlPlan(preview: preview, preparedCommit: f.prepared(preview)))
        try f.publishCopy(preview)
        let reader = try StorageRelocationCoordinator(applicationSupportURL: f.root, fileSystem: LocalFileSystem(),
            identitySource: { secure in
                StorageVolumeIdentity(device: UInt64(secure.rootIdentity.device), inode: UInt64(secure.rootIdentity.inode),
                    volumeUUID: "00000000-0000-0000-0000-000000000099")
            }, activityProvider: f.registry)
        XCTAssertThrowsError(try f.repository.tryWithExclusiveAccess { access in
            try reader.recover(transactionID: preview.requestID, repository: f.repository, access: access)
        })
        XCTAssertTrue(f.exists(preview.source.applicationRoot.url))
        XCTAssertTrue(f.exists(preview.destination.applicationRoot.url))
    }

    func testCompletedRelocationMaintenancePreservesEnrollmentAfterUnplug() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        let coordinator = try StorageRelocationCoordinator(applicationSupportURL: f.root, fileSystem: LocalFileSystem(),
            activityProvider: f.registry, availableCapacity: { _ in UInt64.max }, supportsPermissions: { _ in true },
            transactionBoundary: { boundary in
                if boundary == .beforeCompletionReceipt(preview.requestID) {
                    XCTAssertEqual(try f.coordinator.enrollmentStore.record(applicationStorageID: f.application.storageID)?.baseRootPath,
                        preview.source.canonicalBaseRootURL.path)
                }
                if boundary == .beforeRetirementMarkerRemoval(preview.requestID) { throw Interruption.stopped }
            })
        XCTAssertNoThrow(try coordinator.execute(preview, preparedCommit: f.prepared(preview), repository: f.repository))
        let expected = try XCTUnwrap(coordinator.enrollmentStore.record(applicationStorageID: f.application.storageID))
        XCTAssertEqual(expected.baseRootPath, preview.destination.canonicalBaseRootURL.path)
        try FileManager.default.moveItem(at: f.destination, to: f.root.appendingPathComponent("Unplugged"))
        _ = try f.repository.tryWithExclusiveAccess { access in
            try f.coordinator.maintainControlState(repository: f.repository, access: access)
        }
        let record = try XCTUnwrap(f.coordinator.enrollmentStore.record(applicationStorageID: f.application.storageID))
        XCTAssertEqual(record, expected)
        XCTAssertEqual(try f.coordinator.control.itemState(at: f.coordinator.controlPlanPath(preview.requestID)), .missing)
    }

    func testRelocationRollbackPreservesConfiguredAliasEnrollment() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let alias = f.root.appendingPathComponent("SourceAlias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.source)
        var application = f.application
        application.baseStoragePath = alias.path
        let version = try f.repository.save([application], expectedVersion: f.version).versionToken
        let preview = try f.coordinator.prepare(application: application, destinationBaseRoot: f.destination.path,
            expectedVersion: version)
        let prepared = try f.repository.prepare([preview.relocatedApplication], expectedVersion: version)
        try f.coordinator.writeControlPlan(f.coordinator.makeControlPlan(preview: preview, preparedCommit: prepared))
        XCTAssertEqual(try f.recover(preview), .rolledBack)
        let record = try XCTUnwrap(f.coordinator.enrollmentStore.record(applicationStorageID: application.storageID))
        XCTAssertEqual(record.baseRootPath, alias.path)
    }

    func testRelocationUpdatesEnrollmentAfterCommit() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        let destinationUUID = "00000000-0000-0000-0000-000000000002"
        let coordinator = try StorageRelocationCoordinator(applicationSupportURL: f.root, fileSystem: LocalFileSystem(),
            identitySource: { secure in
                StorageVolumeIdentity(device: UInt64(secure.rootIdentity.device), inode: UInt64(secure.rootIdentity.inode),
                    volumeUUID: URL(fileURLWithPath: secure.rootPath).lastPathComponent == "Destination" ? destinationUUID : Self.volume)
            }, activityProvider: f.registry, availableCapacity: { _ in UInt64.max }, supportsPermissions: { _ in true })
        _ = try coordinator.execute(preview, preparedCommit: f.prepared(preview), repository: f.repository)
        let record = try XCTUnwrap(coordinator.enrollmentStore.record(applicationStorageID: f.application.storageID))
        XCTAssertEqual(record.baseRootPath, preview.destination.canonicalBaseRootURL.path)
        XCTAssertEqual(record.volumeUUID, destinationUUID)
    }
}

// Model a completed plan retained by the previous build, without using the new
// executor that immediately retires its records.
func publishCompletedRelocationForRetentionTest(_ fixture: RelocationAuditFixture,
    preview: StorageRelocationPreview) throws {
    let coordinator = fixture.coordinator
    let plan = try coordinator.loadControlPlan(preview.requestID)
    _ = try coordinator.writeControlReceipt(plan: plan, completion: .rolledBack)
}
