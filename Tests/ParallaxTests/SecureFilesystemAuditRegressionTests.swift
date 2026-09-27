import Darwin
import Foundation
import XCTest
@testable import Parallax

final class SecureFilesystemAuditRegressionTests: XCTestCase {
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Parallax-FSAudit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testZeroByteWriteFailsImmediatelyAndRemovesCreatedFile() throws {
        let fs = try SecureManagedFileSystem(rootURL: root)
        var calls = 0
        XCTAssertThrowsError(try fs.write(Data("data".utf8), to: SecureManagedPath(["data"]), writeOperation: { _, _, _ in
            calls += 1
            if calls == 1 { return 0 }
            errno = EIO
            return -1
        }))
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("data").path))
    }

    func testDirectoryHardLinkCountRejectsMultipleLinks() throws {
        XCTAssertNoThrow(try SecureManagedFileSystem.validateDirectoryLinkCount(1))
        XCTAssertThrowsError(try SecureManagedFileSystem.validateDirectoryLinkCount(2))
    }

    func testCopyRefusesImmutableSourceBeforeCreatingDestination() throws {
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("copy")
        try Data("keep".utf8).write(to: source)
        XCTAssertEqual(chflags(source.path, UInt32(UF_IMMUTABLE)), 0)
        defer {
            _ = chflags(source.path, 0)
            _ = chflags(destination.path, 0)
        }
        let fs = try SecureManagedFileSystem(rootURL: root)
        XCTAssertThrowsError(try fs.copyTree(from: SecureManagedPath(["source"]), to: SecureManagedPath(["copy"])))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCopyFailureCleansCompletedReadOnlyChildren() throws {
        let source = root.appendingPathComponent("source")
        let child = source.appendingPathComponent("a-readonly")
        let reachedFailure = root.appendingPathComponent("reached-failure")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: child.appendingPathComponent("data"))
        try Data("later".utf8).write(to: source.appendingPathComponent("z-fail"))
        XCTAssertEqual(chmod(child.path, 0o555), 0)
        defer { _ = chmod(child.path, 0o700) }
        let fs = try SecureManagedFileSystem(rootURL: root) { boundary in
            if boundary == .afterCopyDestinationCreation("z-fail") {
                try Data().write(to: reachedFailure)
                throw ProbeError.stop
            }
        }
        XCTAssertThrowsError(try fs.copyTree(from: SecureManagedPath(["source"]), to: SecureManagedPath(["copy"])))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reachedFailure.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("copy").path))
        XCTAssertEqual(try Data(contentsOf: child.appendingPathComponent("data")), Data("keep".utf8))
        XCTAssertEqual(try LocalFileSystem().attributesOfItem(at: child).posixPermissions, 0o555)
    }

    func testAnotherUsersPrivateDirectoryIsRejected() throws {
        var status = stat()
        status.st_mode = mode_t(S_IFDIR | 0o700)
        status.st_uid = geteuid() ^ 1
        let fs = try SecureManagedFileSystem(rootURL: root)
        XCTAssertThrowsError(try SecureManagedFileSystem.validateOwnedDirectory(
            status, descriptor: fs.rootDescriptor, path: root.path
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains(self.root.path))
        }
        status.st_uid = geteuid()
        XCTAssertNoThrow(try SecureManagedFileSystem.validateOwnedDirectory(
            status, descriptor: fs.rootDescriptor, path: root.path
        ))
    }

    func testFileSwappedForFIFOIsRejectedAfterNonblockingOpen() throws {
        for operation in 0..<3 {
            let source = root.appendingPathComponent("source-\(operation)")
            try Data("keep".utf8).write(to: source)
            var original = stat()
            XCTAssertEqual(lstat(source.path, &original), 0)
            let fs = try SecureManagedFileSystem(rootURL: root) { boundary in
                if case let .beforeOpenFile(_, flags) = boundary {
                    XCTAssertNotEqual(flags & O_NONBLOCK, 0)
                    guard flags & O_NONBLOCK != 0 else { throw ProbeError.stop }
                    try FileManager.default.removeItem(at: source)
                    XCTAssertEqual(mkfifo(source.path, 0o600), 0)
                }
            }
            let path = try SecureManagedPath([source.lastPathComponent])
            switch operation {
            case 0:
                XCTAssertThrowsError(try fs.manifest(at: path))
            case 1:
                XCTAssertThrowsError(try fs.rename(from: path, to: SecureManagedPath(["renamed"])))
            default:
                let copied = try openCopyDestination(directory: false)
                defer { close(copied.descriptor) }
                XCTAssertThrowsError(try fs.copyItem(sourceParent: fs.rootDescriptor,
                    sourceName: source.lastPathComponent, destinationParent: fs.rootDescriptor,
                    destinationName: "copy", sourceStatus: original,
                    destinationDescriptor: copied.descriptor, destinationStatus: copied.status,
                    destinationFileSystem: fs))
            }
            var final = stat()
            XCTAssertEqual(lstat(source.path, &final), 0)
            XCTAssertEqual(final.st_mode & S_IFMT, S_IFIFO)
        }
    }

    private func openCopyDestination(directory: Bool) throws -> (descriptor: Int32, status: stat) {
        let path = root.appendingPathComponent("copy").path
        let flags = directory ? O_RDONLY | O_DIRECTORY : O_RDWR | O_CREAT | O_EXCL
        let descriptor = open(path, flags | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            close(descriptor)
            throw POSIXError(.EIO)
        }
        return (descriptor, status)
    }

    func testCopyVerificationPreservesUnrecognizedEntries() throws {
        let source = root.appendingPathComponent("source")
        let unexpected = root.appendingPathComponent("copy/unrecognized")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let fs = try SecureManagedFileSystem(rootURL: root) { boundary in
            if boundary == .afterCopyDestinationCreation("copy") {
                try Data("keep".utf8).write(to: unexpected)
            }
        }
        XCTAssertThrowsError(try fs.copyTree(from: SecureManagedPath(["source"]), to: SecureManagedPath(["copy"])))
        XCTAssertEqual(try? Data(contentsOf: unexpected), Data("keep".utf8))
    }

    func testOwnedRemovalRejectsAnEntryWhoseKindChanged() throws {
        let source = root.appendingPathComponent("source")
        let item = source.appendingPathComponent("item")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("old".utf8).write(to: item)
        let fs = try SecureManagedFileSystem(rootURL: root) { boundary in
            if boundary == .beforeRemoveOwnedTree {
                try FileManager.default.removeItem(at: item)
                try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
            }
        }
        let path = try SecureManagedPath(["source"])
        guard case let .present(identity) = try fs.itemState(at: path) else {
            return XCTFail("Missing fixture")
        }
        let manifest = try fs.manifest(at: path)
        XCTAssertThrowsError(try fs.removeOwnedTree(at: path, expectedIdentity: identity, expectedManifest: manifest))
        XCTAssertEqual(try LocalFileSystem().attributesOfItem(at: item).kind, .directory)
    }

    func testCopyPreservesReadOnlyFileAndDirectoryModesAfterPopulation() throws {
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let file = source.appendingPathComponent("data")
        try Data("keep".utf8).write(to: file)
        XCTAssertEqual(chmod(file.path, 0o444), 0)
        XCTAssertEqual(chmod(source.path, 0o555), 0)
        defer {
            _ = chmod(source.path, 0o700)
            _ = chmod(root.appendingPathComponent("copy").path, 0o700)
        }
        let fs = try SecureManagedFileSystem(rootURL: root)
        try fs.copyTree(from: SecureManagedPath(["source"]), to: SecureManagedPath(["copy"]))
        XCTAssertEqual(try fs.manifest(at: SecureManagedPath(["source"])),
                       try fs.manifest(at: SecureManagedPath(["copy"])))
    }

    func testCopyDoesNotWriteThroughSwappedDestinationHardLink() throws {
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("copy")
        let outside = root.appendingPathComponent("outside")
        try Data("private source".utf8).write(to: source)
        try Data("outside sentinel".utf8).write(to: outside)
        let fs = try SecureManagedFileSystem(rootURL: root) { boundary in
            if boundary == .afterCopyDestinationCreation("copy") {
                try FileManager.default.removeItem(at: destination)
                XCTAssertEqual(link(outside.path, destination.path), 0)
            }
        }
        XCTAssertThrowsError(try fs.copyTree(from: SecureManagedPath(["source"]),
                                            to: SecureManagedPath(["copy"])))
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside sentinel".utf8))
    }

    func testCopyRejectsDestinationDirectoryReplacement() throws {
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("copy")
        let displaced = root.appendingPathComponent("displaced")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("private".utf8).write(to: source.appendingPathComponent("data"))
        let fs = try SecureManagedFileSystem(rootURL: root) { boundary in
            if boundary == .afterCopyDestinationCreation("copy") {
                try FileManager.default.moveItem(at: destination, to: displaced)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            }
        }
        XCTAssertThrowsError(try fs.copyTree(from: SecureManagedPath(["source"]),
                                            to: SecureManagedPath(["copy"])))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("data").path))
    }

    func testCopyRejectsNestedDestinationBeforeCreatingParents() throws {
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let fs = try SecureManagedFileSystem(rootURL: root) { boundary in
            if boundary == .afterCopyDestinationCreation("copy") { throw ProbeError.stop }
        }
        XCTAssertThrowsError(try fs.copyTree(from: SecureManagedPath(["source"]),
                                            to: SecureManagedPath(["source", "new-parent", "copy"])))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("new-parent").path))
        let otherHandle = try SecureManagedFileSystem(rootURL: source)
        XCTAssertThrowsError(try fs.copyTree(from: SecureManagedPath(["source"]),
                                            to: SecureManagedPath(["copy"]), in: otherHandle))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("copy").path))
    }

    func testOwnedRemovalRejectsNewEntriesWithoutDeletingThem() throws {
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let added = source.appendingPathComponent("unexpected")
        let fs = try SecureManagedFileSystem(rootURL: root) { boundary in
            if boundary == .beforeRemoveOwnedTree { try Data("keep".utf8).write(to: added) }
        }
        guard case let .present(identity) = try fs.itemState(at: SecureManagedPath(["source"])) else {
            return XCTFail("Missing fixture")
        }
        let manifest = try fs.manifest(at: SecureManagedPath(["source"]))
        XCTAssertThrowsError(try fs.removeOwnedTree(at: SecureManagedPath(["source"]),
                                                   expectedIdentity: identity, expectedManifest: manifest))
        XCTAssertEqual(try Data(contentsOf: added), Data("keep".utf8))
    }

    func testOwnedRemovalRejectsReplacementRootWithSameManifest() throws {
        let source = root.appendingPathComponent("source")
        let original = root.appendingPathComponent("original")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let fs = try SecureManagedFileSystem(rootURL: root) { boundary in
            if boundary == .beforeRemoveOwnedTree {
                try FileManager.default.moveItem(at: source, to: original)
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            }
        }
        guard case let .present(identity) = try fs.itemState(at: SecureManagedPath(["source"])) else {
            return XCTFail("Missing fixture")
        }
        let manifest = try fs.manifest(at: SecureManagedPath(["source"]))
        XCTAssertThrowsError(try fs.removeOwnedTree(at: SecureManagedPath(["source"]),
                                                   expectedIdentity: identity, expectedManifest: manifest))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testAllWalkersRejectAnItemOnAnotherDevice() throws {
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("copy")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: source.appendingPathComponent("data"))
        let fs = try SecureManagedFileSystem(rootURL: root)
        var status = stat()
        XCTAssertEqual(lstat(source.path, &status), 0)
        let otherDevice = status.st_dev ^ 1
        XCTAssertThrowsError(try fs.preflightItem(parent: fs.rootDescriptor, name: "source", rootDevice: otherDevice))
        var entries: [SecureManagedManifest.Entry] = []
        XCTAssertThrowsError(try fs.appendManifestEntries(parent: fs.rootDescriptor, name: "source",
            relativeComponents: [], entries: &entries, rootDevice: otherDevice))
        let copied = try openCopyDestination(directory: true)
        defer { close(copied.descriptor) }
        XCTAssertThrowsError(try fs.copyItem(sourceParent: fs.rootDescriptor, sourceName: "source",
            destinationParent: fs.rootDescriptor, destinationName: "copy", sourceStatus: status, rootDevice: otherDevice,
            destinationDescriptor: copied.descriptor, destinationStatus: copied.status,
            destinationFileSystem: fs))
        XCTAssertThrowsError(try fs.removeItem(parent: fs.rootDescriptor, name: "source",
            expectedStatus: status, rootDevice: otherDevice))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("data")), Data("keep".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("data").path))
    }

    func testManifestCopyAndRenameFileOpensCannotBlockOnFIFO() throws {
        let source = root.appendingPathComponent("source")
        try Data("data".utf8).write(to: source)
        let fs = try SecureManagedFileSystem(rootURL: root) { boundary in
            if case let .beforeOpenFile(_, flags) = boundary {
                XCTAssertNotEqual(flags & O_NONBLOCK, 0)
                throw ProbeError.stop
            }
        }
        XCTAssertThrowsError(try fs.manifest(at: SecureManagedPath(["source"])))
        XCTAssertThrowsError(try fs.rename(from: SecureManagedPath(["source"]), to: SecureManagedPath(["renamed"])))
        var status = stat()
        XCTAssertEqual(lstat(source.path, &status), 0)
        let copied = try openCopyDestination(directory: false)
        defer { close(copied.descriptor) }
        XCTAssertThrowsError(try fs.copyItem(sourceParent: fs.rootDescriptor, sourceName: "source",
            destinationParent: fs.rootDescriptor, destinationName: "copy", sourceStatus: status,
            destinationDescriptor: copied.descriptor, destinationStatus: copied.status,
            destinationFileSystem: fs))
    }

    func testExistingWritableNamespaceIsTightened() throws {
        let namespace = root.appendingPathComponent(".parallax")
        try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(namespace.path, 0o775), 0)
        XCTAssertNoThrow(try ManagedPathResolver(fileSystem: LocalFileSystem()).resolve(
            configuredBaseRoot: root.path, applicationStorageID: UUID(), profileStorageID: UUID()))
        XCTAssertEqual(try LocalFileSystem().attributesOfItem(at: namespace).posixPermissions, 0o755)
        XCTAssertEqual(chmod(namespace.path, 0o775), 0)
        let fs = try SecureManagedFileSystem(rootURL: root)
        XCTAssertNoThrow(try fs.createDirectory(at: SecureManagedPath([".parallax", "Applications", "new"])))
        XCTAssertEqual(try LocalFileSystem().attributesOfItem(at: namespace).posixPermissions, 0o755)
    }

    func testFilesystemErrorsHaveActionableLocalizedDescriptions() {
        for error: SecureManagedFileSystemError in [.invalidRoot, .symbolicLinkEncountered,
            .hardLinkEncountered, .manifestMismatch, .systemCall(operation: "open", code: EMFILE)] {
            XCTAssertFalse(error.localizedDescription.contains("SecureManagedFileSystemError"))
        }
        for code in [EMFILE, ENFILE] {
            let error = SecureManagedFileSystemError.systemCall(operation: "open", code: code)
            XCTAssertEqual(error.localizedDescription, String(localized: "The managed folder tree exceeds the available file descriptor limit. Close other applications or use a shallower folder tree."))
        }
        let message = TrustedParallaxContainerError.systemCall(operation: "fsync obscure internal operation", code: EIO).localizedDescription
        XCTAssertFalse(message.contains("fsync obscure internal operation"))
    }
}

private enum ProbeError: Error { case stop }
