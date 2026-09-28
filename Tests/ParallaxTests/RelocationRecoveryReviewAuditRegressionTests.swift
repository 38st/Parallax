import Foundation
import XCTest
@testable import Parallax

final class RelocationRecoveryReviewAuditRegressionTests: XCTestCase {
    func testPriorWithDeletedDestinationCompletesRollback() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        try f.publishPlan(preview)
        try FileManager.default.removeItem(at: f.destination)
        XCTAssertEqual(try f.recover(preview), .rolledBack)
        XCTAssertTrue(f.exists(preview.source.applicationRoot.url))
        XCTAssertFalse(f.exists(f.destination))
    }

    func testPriorWithAbsentCustomMountCompletesRollback() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        try f.publishPlan(preview)
        try f.coordinator.enrollmentStore.recordVerifiedRoot(applicationStorageID: f.application.storageID,
            baseRoot: f.destination, volumeUUID: "00000000-0000-0000-0000-000000000099")
        try FileManager.default.moveItem(at: f.destination, to: f.root.appendingPathComponent("Unmounted"))
        XCTAssertEqual(try f.recover(preview), .rolledBack)
        XCTAssertFalse(f.exists(f.destination))
    }

    func testPriorWithChangedSourceAndNoPublishedCopyCompletesRollback() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        try f.publishPlan(preview)
        try FileManager.default.moveItem(at: f.source, to: f.root.appendingPathComponent("Original"))
        try FileManager.default.createDirectory(at: f.source, withIntermediateDirectories: true)
        XCTAssertEqual(try f.recover(preview), .rolledBack)
    }

    func testTargetWithRecreatedSourceKeepsLeftovers() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        try f.publishPlan(preview)
        try f.publishCopy(preview)
        _ = try f.repository.save([preview.relocatedApplication], expectedVersion: f.version)
        try FileManager.default.moveItem(at: f.source, to: f.root.appendingPathComponent("Original"))
        try FileManager.default.createDirectory(at: preview.source.applicationRoot.url, withIntermediateDirectories: true)
        let sentinel = preview.source.applicationRoot.url.appendingPathComponent("new-data")
        try Data("preserve".utf8).write(to: sentinel)
        guard case .committed(let outcome) = try f.recover(preview) else { return XCTFail("Expected commit") }
        XCTAssertEqual(outcome.leftoverSourcePaths, [preview.source.applicationRoot.url.path])
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve".utf8))
    }

    func testTargetWithDifferentSourceVolumeKeepsLeftovers() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        try f.publishPlan(preview)
        try f.publishCopy(preview)
        _ = try f.repository.save([preview.relocatedApplication], expectedVersion: f.version)
        let reader = try StorageRelocationCoordinator(applicationSupportURL: f.root, fileSystem: LocalFileSystem(),
            identitySource: { secure in
                let actual = try StorageVolumeIdentity.read(secure)
                return StorageVolumeIdentity(device: actual.device, inode: actual.inode,
                    volumeUUID: URL(fileURLWithPath: secure.rootPath).lastPathComponent == "Source" ? "00000000-0000-0000-0000-000000000099" : actual.volumeUUID)
            }, activityProvider: f.registry)
        let result = try f.repository.tryWithExclusiveAccess { access in
            try reader.recover(transactionID: preview.requestID, repository: f.repository, access: access)
        }
        guard case .acquired(.committed(let outcome)) = result else { return XCTFail("Expected commit") }
        XCTAssertEqual(outcome.leftoverSourcePaths, [preview.source.applicationRoot.url.path])
        XCTAssertTrue(f.exists(preview.source.applicationRoot.url))
    }

    func testTargetWithMissingDestinationRemainsPending() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        try f.publishPlan(preview)
        try f.publishCopy(preview)
        _ = try f.repository.save([preview.relocatedApplication], expectedVersion: f.version)
        try FileManager.default.removeItem(at: f.destination)
        XCTAssertThrowsError(try f.recover(preview))
        XCTAssertEqual(try f.coordinator.pendingRelocations().count, 1)
        XCTAssertTrue(f.exists(preview.source.applicationRoot.url))
    }

    func testRootWithoutRecordedUUIDStillRequiresOriginalDevice() {
        let binding = StorageTransactionRootBinding(path: "/fixture", volumeID: 1, fileID: 2, identityVersion: 1)
        XCTAssertFalse(binding.matches(StorageVolumeIdentity(device: 3, inode: 2, volumeUUID: nil)))
        XCTAssertFalse(binding.matches(StorageVolumeIdentity(device: 3, inode: 2,
            volumeUUID: "00000000-0000-0000-0000-000000000099")))
        XCTAssertTrue(binding.matches(StorageVolumeIdentity(device: 1, inode: 2, volumeUUID: nil)))
    }
}
