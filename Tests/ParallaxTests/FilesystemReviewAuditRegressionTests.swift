import Darwin
import Foundation
import XCTest
@testable import Parallax

final class FilesystemReviewAuditRegressionTests: XCTestCase {
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Parallax-FSReview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCopyAcceptsFileIdentityAssignedOnFirstWrite() throws {
        var calls = SecureManagedFileSystemCalls()
        calls.status = { descriptor, status in
            let result = fstat(descriptor, status)
            if result == 0 { Self.simulateEmptyFileIdentity(status) }
            return result
        }
        calls.statusAt = { parent, name, status, flags in
            let result = fstatat(parent, name, status, flags)
            if result == 0 { Self.simulateEmptyFileIdentity(status) }
            return result
        }
        let source = try SecureManagedFileSystem(rootURL: root)
        let destination = try SecureManagedFileSystem(rootURL: root, systemCalls: calls)
        try Data("payload".utf8).write(to: root.appendingPathComponent("file"))
        try source.copyTree(from: SecureManagedPath(["file"]),
                            to: SecureManagedPath(["copy"]), in: destination)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("copy")), Data("payload".utf8))
        calls.sync = { _, barrier in
            if !barrier { errno = EIO; return -1 }
            return 0
        }
        let failingDestination = try SecureManagedFileSystem(rootURL: root, systemCalls: calls)
        XCTAssertThrowsError(try source.copyTree(from: SecureManagedPath(["file"]),
            to: SecureManagedPath(["failed-copy"]), in: failingDestination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("failed-copy").path))
    }

    private static func simulateEmptyFileIdentity(_ status: UnsafeMutablePointer<stat>) {
        if status.pointee.st_mode & S_IFMT == S_IFREG, status.pointee.st_size == 0 {
            status.pointee.st_ino ^= UInt64.max
        }
    }

    func testCopyAndRemovalFlushItemsButUseOneFullSyncBarrier() throws {
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: source.appendingPathComponent("nested/file"))
        let trace = ReviewSyncTrace()
        var calls = SecureManagedFileSystemCalls()
        calls.sync = { _, barrier in trace.append(barrier); return 0 }
        let fs = try SecureManagedFileSystem(rootURL: root, systemCalls: calls)
        try fs.copyTree(from: SecureManagedPath(["source"]), to: SecureManagedPath(["copy"]))
        XCTAssertEqual(trace.values.filter { $0 }.count, 1)
        XCTAssertEqual(trace.values.filter { !$0 }.count, 3)
        XCTAssertEqual(trace.values.last, true)
        trace.clear()
        try fs.removeTree(at: SecureManagedPath(["copy"]))
        XCTAssertEqual(trace.values.filter { $0 }.count, 1)
        XCTAssertEqual(trace.values.filter { !$0 }.count, 2)
        XCTAssertEqual(trace.values.last, true)
    }

    func testTopLevelCreationFailureCleansOnlyCreatedDestination() throws {
        for directory in [false, true] {
            let name = directory ? "directory" : "file"
            let source = root.appendingPathComponent(name)
            if directory {
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            } else {
                try Data("payload".utf8).write(to: source)
            }
            let fs = try SecureManagedFileSystem(rootURL: root) { boundary in
                if boundary == .afterCopyDestinationCreation("copy") { throw ReviewError.injected }
            }
            XCTAssertThrowsError(try fs.copyTree(from: SecureManagedPath([name]), to: SecureManagedPath(["copy"])))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("copy").path))
        }
    }

    func testCreationFailurePreservesAnEmptyReplacementDirectory() throws {
        let source = root.appendingPathComponent("source")
        let replacement = root.appendingPathComponent("copy")
        let displaced = root.appendingPathComponent("displaced")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let fs = try SecureManagedFileSystem(rootURL: root) { boundary in
            if boundary == .afterCopyDestinationCreation("copy") {
                try FileManager.default.moveItem(at: replacement, to: displaced)
                try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
            }
        }
        XCTAssertThrowsError(try fs.copyTree(from: SecureManagedPath(["source"]), to: SecureManagedPath(["copy"])))
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: displaced.path))
    }

    func testNamespaceChainsAreTightenedButProviderDataIsUnchanged() throws {
        let resolver = ManagedPathResolver(fileSystem: LocalFileSystem())
        let application = UUID()
        let profile = UUID()
        let paths = try resolver.resolve(configuredBaseRoot: root.path,
            applicationStorageID: application, profileStorageID: profile)
        try FileManager.default.createDirectory(at: paths.userData.url, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.archiveRoot.url, withIntermediateDirectories: true)
        let transactions = root.appendingPathComponent(".parallax/Transactions")
        try FileManager.default.createDirectory(at: transactions, withIntermediateDirectories: true)
        let directories = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            .map { root.appendingPathComponent($0) }
        for directory in directories { XCTAssertEqual(chmod(directory.path, 0o775), 0) }
        _ = try resolver.resolve(configuredBaseRoot: root.path,
            applicationStorageID: application, profileStorageID: profile)
        for directory in directories {
            let mode = directory.path == paths.userData.url.path ? 0o775 : 0o755
            XCTAssertEqual(try LocalFileSystem().attributesOfItem(at: directory).posixPermissions, mode)
        }
    }

    func testCleanupUsesCreatedEntriesWhenSourceChangesDuringCopy() throws {
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let fs = try SecureManagedFileSystem(rootURL: root) { boundary in
            if boundary == .afterCopyDestinationCreation("copy") {
                try Data("late addition".utf8).write(to: source.appendingPathComponent("late"))
            }
        }
        XCTAssertThrowsError(try fs.copyTree(from: SecureManagedPath(["source"]), to: SecureManagedPath(["copy"])))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("copy").path))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("late")), Data("late addition".utf8))
    }

    func testCleanupRemovesCreatedChildrenButPreservesUnknownEntries() throws {
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("copied".utf8).write(to: source.appendingPathComponent("known"))
        let unexpected = root.appendingPathComponent("copy/unexpected")
        let fs = try SecureManagedFileSystem(rootURL: root) { boundary in
            if boundary == .afterCopyDestinationCreation("copy") {
                try Data("keep".utf8).write(to: unexpected)
            }
        }
        XCTAssertThrowsError(try fs.copyTree(from: SecureManagedPath(["source"]), to: SecureManagedPath(["copy"])))
        XCTAssertEqual(try Data(contentsOf: unexpected), Data("keep".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("copy/known").path))
    }

    func testCleanupPreservesReplacementOfAnAlreadyCopiedChild() throws {
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        for name in ["a", "z"] { try Data(name.utf8).write(to: source.appendingPathComponent(name)) }
        let copied = root.appendingPathComponent("copy/a")
        let kept = root.appendingPathComponent("kept")
        let fs = try SecureManagedFileSystem(rootURL: root) { boundary in
            if boundary == .afterCopyDestinationCreation("z") {
                try FileManager.default.moveItem(at: copied, to: kept)
                try Data("replacement".utf8).write(to: copied)
                throw ReviewError.injected
            }
        }
        XCTAssertThrowsError(try fs.copyTree(from: SecureManagedPath(["source"]), to: SecureManagedPath(["copy"])))
        XCTAssertEqual(try? Data(contentsOf: copied), Data("replacement".utf8))
    }

    func testACLNamespaceIsRejectedWithoutTighteningAndNamesItsPath() throws {
        let namespace = root.appendingPathComponent(".parallax")
        try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: false)
        try POSIXTestSupport.runChmod(["+a", "everyone allow add_file,delete_child", namespace.path])
        defer { try? POSIXTestSupport.runChmod(["-N", namespace.path]) }
        for mode in [mode_t(0o755), mode_t(0o775)] {
            XCTAssertEqual(chmod(namespace.path, mode), 0)
            XCTAssertThrowsError(try ManagedPathResolver(fileSystem: LocalFileSystem()).resolve(
                configuredBaseRoot: root.path, applicationStorageID: UUID(), profileStorageID: UUID()
            )) { error in
                XCTAssertTrue(error.localizedDescription.contains(namespace.path), error.localizedDescription)
            }
            XCTAssertEqual(try LocalFileSystem().attributesOfItem(at: namespace).posixPermissions, Int(mode))
        }
    }

    func testFullSyncFailuresFallBackAndReportOnlyFallbackFailure() {
        for code in [ENOTSUP, EOPNOTSUPP, EINVAL, ENOTTY, ENOSYS, EIO] {
            var fallbackCalls = 0
            XCTAssertEqual(synchronizeFileDescriptor(-1, fullSync: { _ in
                errno = code; return -1
            }, sync: { _ in fallbackCalls += 1; return 0 }), 0)
            XCTAssertEqual(fallbackCalls, 1)
        }
        XCTAssertEqual(synchronizeFileDescriptor(-1, fullSync: { _ in
            errno = EIO; return -1
        }, sync: { _ in errno = ENOSPC; return -1 }), -1)
        XCTAssertEqual(errno, ENOSPC)
    }

    func testPermissionRestoreFailureIsReported() throws {
        let directory = root.appendingPathComponent("readonly")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(directory.path, 0o555), 0)
        defer { _ = chmod(directory.path, 0o755) }
        var calls = SecureManagedFileSystemCalls()
        calls.sync = { _, _ in errno = EIO; return -1 }
        calls.changeMode = { descriptor, mode in
            if mode == 0o555 { errno = EPERM; return -1 }
            return fchmod(descriptor, mode)
        }
        let fs = try SecureManagedFileSystem(rootURL: root, systemCalls: calls)
        XCTAssertThrowsError(try fs.removeTree(at: SecureManagedPath(["readonly"]))) { error in
            XCTAssertTrue(error.localizedDescription.contains(directory.path), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("permissions"), error.localizedDescription)
        }
    }

    func testSystemCallDiagnosticsRetainOperationWithoutLocalizingIt() {
        for error: any Error in [
            SecureManagedFileSystemError.systemCall(operation: "inspect copied file", code: EIO),
            TrustedParallaxContainerError.systemCall(operation: "inspect copied file", code: EIO),
        ] {
            XCTAssertFalse(error.localizedDescription.contains("inspect copied file"))
            let diagnostic = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
            XCTAssertTrue(diagnostic?.contains("inspect copied file") == true)
        }
    }

    func testUnusedOperationInterpolationCatalogKeyIsRemoved() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for language in ["en", "es"] {
            let catalog = repository.appendingPathComponent("Sources/Parallax/Resources/\(language).lproj/Localizable.strings")
            let text = try String(contentsOf: catalog, encoding: .utf8)
            XCTAssertFalse(text.contains("\"Parallax could not %@: %@.\""))
        }
    }

    func testMissingRootBelowUnmountedVolumeIsUnavailable() throws {
        let mounts = root.appendingPathComponent("Volumes")
        let volume = mounts.appendingPathComponent("Share")
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        let base = volume.appendingPathComponent("Storage")
        let resolver = ManagedPathResolver(fileSystem: LocalFileSystem(), mountsDirectory: mounts,
            mountCheck: { candidate in XCTAssertEqual(candidate.path, volume.path); return false })
        XCTAssertThrowsError(try resolver.resolve(configuredBaseRoot: base.path,
            applicationStorageID: UUID(), profileStorageID: UUID())) { error in
                XCTAssertEqual((error as? ManagedPathError)?.code, .baseRootUnavailable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))
    }

    func testMountedVolumeAndOrdinaryMissingRootRemainAllowed() throws {
        let mounts = root.appendingPathComponent("Volumes")
        let volume = mounts.appendingPathComponent("Share")
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        let resolver = ManagedPathResolver(fileSystem: LocalFileSystem(), mountsDirectory: mounts,
            mountCheck: { _ in true })
        let resolved = try resolver.resolve(configuredBaseRoot: volume.appendingPathComponent("Storage").path,
            applicationStorageID: UUID(), profileStorageID: UUID())
        let disconnected = ManagedPathResolver(fileSystem: LocalFileSystem(), mountsDirectory: mounts,
            mountCheck: { _ in false })
        XCTAssertThrowsError(try disconnected.revalidateForMutation(resolved.userData))
        let local = ManagedPathResolver(fileSystem: LocalFileSystem(), mountsDirectory: mounts,
            mountCheck: { _ in XCTFail("Local roots do not require a mount"); return false })
        XCTAssertNoThrow(try local.resolve(configuredBaseRoot: root.appendingPathComponent("NewLocalRoot").path,
            applicationStorageID: UUID(), profileStorageID: UUID()))
    }
}

private enum ReviewError: Error { case injected }

private final class ReviewSyncTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Bool] = []
    var values: [Bool] { lock.withLock { stored } }
    func append(_ value: Bool) { lock.withLock { stored.append(value) } }
    func clear() { lock.withLock { stored.removeAll() } }
}
