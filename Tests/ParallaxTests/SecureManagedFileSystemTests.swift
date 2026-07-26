import Darwin
import Foundation
import XCTest
@testable import Parallax

final class SecureManagedFileSystemTests: XCTestCase {
    private var temporaryDirectory = FileManager.default.temporaryDirectory
    private var managedRoot = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Parallax-SecureManagedFileSystem-\(UUID().uuidString)",
                isDirectory: true
            )
        managedRoot = temporaryDirectory.appendingPathComponent(
            "Managed",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: managedRoot,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testRelativePathRejectsEmptyDotTraversalSeparatorAndNULComponents() {
        for components in [
            [""],
            ["."],
            [".."],
            ["Profiles/escape"],
            ["Profiles:escape"],
            ["Profiles\u{0}escape"],
        ] {
            XCTAssertThrowsError(try SecureManagedPath(components))
        }
    }

    func testRootMustBeAnAbsoluteRealDirectoryAndNotASymbolicLink() throws {
        let outside = temporaryDirectory.appendingPathComponent(
            "Outside",
            isDirectory: true
        )
        let link = temporaryDirectory.appendingPathComponent(
            "ManagedLink",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertThrowsError(try SecureManagedFileSystem(rootURL: link)) { error in
            XCTAssertEqual(error as? SecureManagedFileSystemError, .symbolicLinkEncountered)
        }
        let relativeURL = try XCTUnwrap(URL(string: "relative/root"))
        XCTAssertThrowsError(
            try SecureManagedFileSystem(rootURL: relativeURL)
        ) { error in
            XCTAssertEqual(error as? SecureManagedFileSystemError, .invalidRoot)
        }
    }

    func testCreateAndWriteStayBeneathPinnedRootAndNeverOverwrite() throws {
        let fileSystem = try makeFileSystem()
        let directory = try SecureManagedPath(["Transactions", "one"])
        let file = try directory.appending("receipt.json")
        let bytes = Data("first".utf8)

        try fileSystem.createDirectory(at: directory)
        try fileSystem.write(bytes, to: file)

        XCTAssertEqual(try Data(contentsOf: url(for: file)), bytes)
        XCTAssertThrowsError(try fileSystem.write(Data("second".utf8), to: file)) { error in
            XCTAssertEqual(
                error as? SecureManagedFileSystemError,
                .unexpectedDestination
            )
        }
        XCTAssertEqual(try Data(contentsOf: url(for: file)), bytes)
    }

    func testStagingDirectoryCreationIsExclusiveAndDurable() throws {
        let fileSystem = try makeFileSystem()
        let transactions = try SecureManagedPath(["Transactions"])
        let transactionID = UUID(
            uuid: (
                0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0x4a, 0xaa,
                0x8a, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa
            )
        )

        try fileSystem.createDirectory(at: transactions)
        let staging = try fileSystem.createStagingDirectory(
            in: transactions,
            transactionID: transactionID
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: url(for: staging).path))
        XCTAssertThrowsError(
            try fileSystem.createStagingDirectory(
                in: transactions,
                transactionID: transactionID
            )
        ) { error in
            XCTAssertEqual(
                error as? SecureManagedFileSystemError,
                .unexpectedDestination
            )
        }
    }

    func testNoFollowWalkRejectsSymlinkAncestorWithoutTouchingOutside() throws {
        let fileSystem = try makeFileSystem()
        let outside = temporaryDirectory.appendingPathComponent(
            "Outside",
            isDirectory: true
        )
        let link = managedRoot.appendingPathComponent(
            "Transactions",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let escaped = try SecureManagedPath(["Transactions", "escaped"])

        XCTAssertThrowsError(try fileSystem.createDirectory(at: escaped)) { error in
            XCTAssertEqual(error as? SecureManagedFileSystemError, .symbolicLinkEncountered)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("escaped").path
            )
        )
    }

    func testRootReplacementIsDetectedBeforeMutation() throws {
        let fileSystem = try makeFileSystem()
        let displacedRoot = temporaryDirectory.appendingPathComponent(
            "Displaced",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: managedRoot, to: displacedRoot)
        try FileManager.default.createDirectory(
            at: managedRoot,
            withIntermediateDirectories: false
        )
        let target = try SecureManagedPath(["must-not-exist"])

        XCTAssertThrowsError(try fileSystem.createDirectory(at: target)) { error in
            XCTAssertEqual(
                error as? SecureManagedFileSystemError,
                .rootIdentityChanged
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: managedRoot.appendingPathComponent("must-not-exist").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: displacedRoot.appendingPathComponent("must-not-exist").path
            )
        )
    }

    func testCopyTreePublishesCompleteCopyAndRejectsUnexpectedDestination() throws {
        let fileSystem = try makeFileSystem()
        let source = try SecureManagedPath(["Profiles", "source"])
        let destination = try SecureManagedPath(["Transactions", "copy"])
        let occupied = try SecureManagedPath(["Transactions", "occupied"])
        try createDirectoryOutsidePrimitive(at: source)
        try Data("profile-data".utf8).write(
            to: url(for: source).appendingPathComponent("Account.db")
        )
        try createDirectoryOutsidePrimitive(at: occupied)
        let sentinel = url(for: occupied).appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)

        try fileSystem.copyTree(from: source, to: destination)

        XCTAssertEqual(
            try Data(
                contentsOf: url(for: destination).appendingPathComponent("Account.db")
            ),
            Data("profile-data".utf8)
        )
        XCTAssertThrowsError(
            try fileSystem.copyTree(from: source, to: occupied)
        ) { error in
            XCTAssertEqual(
                error as? SecureManagedFileSystemError,
                .unexpectedDestination
            )
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }

    func testCopyRejectsHardLinkedSourceAndRemovesPartialDestination() throws {
        let fileSystem = try makeFileSystem()
        let source = try SecureManagedPath(["Profiles", "hard-linked"])
        let destination = try SecureManagedPath(["Transactions", "copy"])
        try createDirectoryOutsidePrimitive(at: source)
        let sourceFile = url(for: source).appendingPathComponent("Account.db")
        let outsideLink = temporaryDirectory.appendingPathComponent("outside-link")
        try Data("shared".utf8).write(to: sourceFile)
        XCTAssertEqual(link(sourceFile.path, outsideLink.path), 0)

        XCTAssertThrowsError(
            try fileSystem.copyTree(from: source, to: destination)
        ) { error in
            XCTAssertEqual(error as? SecureManagedFileSystemError, .hardLinkEncountered)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(for: destination).path))
        XCTAssertEqual(try Data(contentsOf: outsideLink), Data("shared".utf8))
    }

    func testRenameUsesExclusivePublicationAndPreservesBothItemsOnConflict() throws {
        let fileSystem = try makeFileSystem()
        let source = try SecureManagedPath(["Transactions", "ready"])
        let destination = try SecureManagedPath(["Profiles", "active"])
        try createDirectoryOutsidePrimitive(at: source)
        try createDirectoryOutsidePrimitive(at: destination)
        let sourceSentinel = url(for: source).appendingPathComponent("source")
        let destinationSentinel = url(for: destination).appendingPathComponent("destination")
        try Data("source".utf8).write(to: sourceSentinel)
        try Data("destination".utf8).write(to: destinationSentinel)

        XCTAssertThrowsError(
            try fileSystem.rename(from: source, to: destination)
        ) { error in
            XCTAssertEqual(
                error as? SecureManagedFileSystemError,
                .unexpectedDestination
            )
        }
        XCTAssertEqual(try Data(contentsOf: sourceSentinel), Data("source".utf8))
        XCTAssertEqual(
            try Data(contentsOf: destinationSentinel),
            Data("destination".utf8)
        )
    }

    func testRenameRejectsSymlinkLeaf() throws {
        let fileSystem = try makeFileSystem()
        let outside = temporaryDirectory.appendingPathComponent(
            "outside-directory",
            isDirectory: true
        )
        let sourceURL = managedRoot.appendingPathComponent("source-link")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sourceURL, withDestinationURL: outside)
        let source = try SecureManagedPath(["source-link"])
        let destination = try SecureManagedPath(["destination"])

        XCTAssertThrowsError(
            try fileSystem.rename(from: source, to: destination)
        ) { error in
            XCTAssertEqual(error as? SecureManagedFileSystemError, .symbolicLinkEncountered)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(for: destination).path))
    }

    func testRemovePreflightsTreeAndRejectsSymlinkLeafWithoutPartialDeletion() throws {
        let fileSystem = try makeFileSystem()
        let tree = try SecureManagedPath(["Profiles", "unsafe"])
        try createDirectoryOutsidePrimitive(at: tree)
        let ordinaryFile = url(for: tree).appendingPathComponent("ordinary")
        let outsideFile = temporaryDirectory.appendingPathComponent("outside")
        let symlink = url(for: tree).appendingPathComponent("escape")
        try Data("ordinary".utf8).write(to: ordinaryFile)
        try Data("outside".utf8).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outsideFile)

        XCTAssertThrowsError(try fileSystem.removeTree(at: tree)) { error in
            XCTAssertEqual(error as? SecureManagedFileSystemError, .symbolicLinkEncountered)
        }
        XCTAssertEqual(try Data(contentsOf: ordinaryFile), Data("ordinary".utf8))
        XCTAssertEqual(try Data(contentsOf: outsideFile), Data("outside".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlink.path))
    }

    func testRemoveRejectsHardLinkedLeafWithoutDeletingEitherLink() throws {
        let fileSystem = try makeFileSystem()
        let tree = try SecureManagedPath(["Profiles", "hard-linked"])
        try createDirectoryOutsidePrimitive(at: tree)
        let managedFile = url(for: tree).appendingPathComponent("Account.db")
        let outsideLink = temporaryDirectory.appendingPathComponent("outside-link")
        try Data("shared".utf8).write(to: managedFile)
        XCTAssertEqual(link(managedFile.path, outsideLink.path), 0)

        XCTAssertThrowsError(try fileSystem.removeTree(at: tree)) { error in
            XCTAssertEqual(error as? SecureManagedFileSystemError, .hardLinkEncountered)
        }
        XCTAssertEqual(try Data(contentsOf: managedFile), Data("shared".utf8))
        XCTAssertEqual(try Data(contentsOf: outsideLink), Data("shared".utf8))
    }

    func testSuccessfulRenameAndRemoveAreDescriptorRelative() throws {
        let fileSystem = try makeFileSystem()
        let source = try SecureManagedPath(["Transactions", "ready"])
        let destination = try SecureManagedPath(["Profiles", "active"])
        try createDirectoryOutsidePrimitive(at: source)
        try Data("account".utf8).write(
            to: url(for: source).appendingPathComponent("Account.db")
        )

        try fileSystem.rename(from: source, to: destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(for: source).path))
        XCTAssertEqual(
            try Data(
                contentsOf: url(for: destination).appendingPathComponent("Account.db")
            ),
            Data("account".utf8)
        )

        try fileSystem.removeTree(at: destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(for: destination).path))
    }

    func testMissingManagedRootIsCreatedRelativeToPinnedExistingAnchor() throws {
        let anchor = temporaryDirectory.appendingPathComponent(
            "Anchor",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: anchor,
            withIntermediateDirectories: true
        )
        let fileSystem = try SecureManagedFileSystem(
            anchorURL: anchor,
            rootComponents: ["Managed", "Nested"],
            createIfMissing: true
        )
        let target = try SecureManagedPath(["Transactions", "one"])

        try fileSystem.createDirectory(at: target)

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: anchor
                    .appendingPathComponent("Managed/Nested/Transactions/one")
                    .path
            )
        )
    }

    func testMissingManagedRootCreationRejectsSymlinkedAnchorLeaf() throws {
        let realAnchor = temporaryDirectory.appendingPathComponent(
            "RealAnchor",
            isDirectory: true
        )
        let linkAnchor = temporaryDirectory.appendingPathComponent(
            "LinkAnchor",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: realAnchor,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkAnchor,
            withDestinationURL: realAnchor
        )

        XCTAssertThrowsError(
            try SecureManagedFileSystem(
                anchorURL: linkAnchor,
                rootComponents: ["Managed"],
                createIfMissing: true
            )
        ) { error in
            XCTAssertEqual(
                error as? SecureManagedFileSystemError,
                .symbolicLinkEncountered
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: realAnchor.appendingPathComponent("Managed").path
            )
        )
    }

    func testDescriptorSafeCrossRootCopyAndRelocation() throws {
        let destinationRoot = temporaryDirectory.appendingPathComponent(
            "Destination",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: destinationRoot,
            withIntermediateDirectories: true
        )
        let sourceFileSystem = try makeFileSystem()
        let destinationFileSystem = try SecureManagedFileSystem(
            rootURL: destinationRoot
        )
        let copySource = try SecureManagedPath(["Profiles", "copy-source"])
        let copied = try SecureManagedPath(["Profiles", "copied"])
        let moveSource = try SecureManagedPath(["Profiles", "move-source"])
        let moved = try SecureManagedPath(["Profiles", "moved"])
        try createDirectoryOutsidePrimitive(at: copySource)
        try createDirectoryOutsidePrimitive(at: moveSource)
        try Data("copy".utf8).write(
            to: url(for: copySource).appendingPathComponent("Account.db")
        )
        try Data("move".utf8).write(
            to: url(for: moveSource).appendingPathComponent("Account.db")
        )

        try sourceFileSystem.copyTree(
            from: copySource,
            to: copied,
            in: destinationFileSystem
        )
        XCTAssertEqual(
            try sourceFileSystem.manifest(at: copySource),
            try destinationFileSystem.manifest(at: copied)
        )
        XCTAssertEqual(
            try sourceFileSystem.itemState(at: copySource).isPresent,
            true
        )

        try sourceFileSystem.relocateTree(
            from: moveSource,
            to: moved,
            in: destinationFileSystem
        )
        XCTAssertEqual(
            try sourceFileSystem.itemState(at: moveSource),
            .missing
        )
        XCTAssertEqual(
            try Data(
                contentsOf: destinationRoot
                    .appendingPathComponent("Profiles/moved/Account.db")
            ),
            Data("move".utf8)
        )
    }

    func testFDInspectionManifestAndOwnedCleanupRequireExactOwnership() throws {
        let fileSystem = try makeFileSystem()
        let tree = try SecureManagedPath(["Profiles", "owned"])
        try createDirectoryOutsidePrimitive(at: tree)
        let file = url(for: tree).appendingPathComponent("Account.db")
        try Data("original".utf8).write(to: file)
        let state = try fileSystem.itemState(at: tree)
        let identity = try XCTUnwrap(state.identity)
        let manifest = try fileSystem.manifest(at: tree)

        try Data("changed".utf8).write(to: file)

        XCTAssertThrowsError(
            try fileSystem.removeOwnedTree(
                at: tree,
                expectedIdentity: identity,
                expectedManifest: manifest
            )
        ) { error in
            XCTAssertEqual(
                error as? SecureManagedFileSystemError,
                .manifestMismatch
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        let changedManifest = try fileSystem.manifest(at: tree)
        try fileSystem.removeOwnedTree(
            at: tree,
            expectedIdentity: identity,
            expectedManifest: changedManifest
        )
        XCTAssertEqual(try fileSystem.itemState(at: tree), .missing)
    }

    func testBoundaryHookRootSwapBeforeInternalOpenIsRejected() throws {
        let profiles = managedRoot.appendingPathComponent(
            "Profiles",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: profiles,
            withIntermediateDirectories: true
        )
        let hook = SecureBoundaryHookBox()
        let fileSystem = try SecureManagedFileSystem(
            rootURL: managedRoot,
            boundaryHook: hook.call
        )
        let displaced = temporaryDirectory.appendingPathComponent(
            "DisplacedRoot",
            isDirectory: true
        )
        hook.body = { boundary in
            guard boundary == .beforeOpenComponent("Profiles") else { return }
            hook.body = nil
            try FileManager.default.moveItem(at: self.managedRoot, to: displaced)
            try FileManager.default.createDirectory(
                at: self.managedRoot,
                withIntermediateDirectories: false
            )
        }

        XCTAssertThrowsError(
            try fileSystem.createDirectory(
                at: SecureManagedPath(["Profiles", "must-not-exist"])
            )
        ) { error in
            XCTAssertEqual(
                error as? SecureManagedFileSystemError,
                .rootIdentityChanged
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: displaced
                    .appendingPathComponent("Profiles/must-not-exist")
                    .path
            )
        )
    }

    func testBoundaryHookAncestorSymlinkSwapBeforeInternalOpenIsRejected() throws {
        let profiles = managedRoot.appendingPathComponent(
            "Profiles",
            isDirectory: true
        )
        let displaced = managedRoot.appendingPathComponent(
            "Profiles-old",
            isDirectory: true
        )
        let outside = temporaryDirectory.appendingPathComponent(
            "Outside",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: profiles,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        let hook = SecureBoundaryHookBox()
        let fileSystem = try SecureManagedFileSystem(
            rootURL: managedRoot,
            boundaryHook: hook.call
        )
        hook.body = { boundary in
            guard boundary == .beforeOpenComponent("Profiles") else { return }
            hook.body = nil
            try FileManager.default.moveItem(at: profiles, to: displaced)
            try FileManager.default.createSymbolicLink(
                at: profiles,
                withDestinationURL: outside
            )
        }

        XCTAssertThrowsError(
            try fileSystem.createDirectory(
                at: SecureManagedPath(["Profiles", "must-not-exist"])
            )
        ) { error in
            XCTAssertEqual(
                error as? SecureManagedFileSystemError,
                .symbolicLinkEncountered
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("must-not-exist").path
            )
        )
    }

    func testBoundaryHookDestinationAncestorSwapBeforeRenameIsRejected() throws {
        let fileSystemHook = SecureBoundaryHookBox()
        let fileSystem = try SecureManagedFileSystem(
            rootURL: managedRoot,
            boundaryHook: fileSystemHook.call
        )
        let source = try SecureManagedPath(["Transactions", "ready"])
        let destination = try SecureManagedPath(["Profiles", "active"])
        try createDirectoryOutsidePrimitive(at: source)
        try FileManager.default.createDirectory(
            at: managedRoot.appendingPathComponent("Profiles"),
            withIntermediateDirectories: true
        )
        let outside = temporaryDirectory.appendingPathComponent(
            "Outside",
            isDirectory: true
        )
        let profiles = managedRoot.appendingPathComponent("Profiles")
        let displaced = managedRoot.appendingPathComponent("Profiles-old")
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        fileSystemHook.body = { boundary in
            guard boundary == .beforeRename else { return }
            fileSystemHook.body = nil
            try FileManager.default.moveItem(at: profiles, to: displaced)
            try FileManager.default.createSymbolicLink(
                at: profiles,
                withDestinationURL: outside
            )
        }

        XCTAssertThrowsError(
            try fileSystem.rename(from: source, to: destination)
        ) { error in
            XCTAssertEqual(
                error as? SecureManagedFileSystemError,
                .symbolicLinkEncountered
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("active").path
            )
        )
    }

    func testBoundaryHookHardlinkChangeAfterRenameIsRejected() throws {
        let hook = SecureBoundaryHookBox()
        let fileSystem = try SecureManagedFileSystem(
            rootURL: managedRoot,
            boundaryHook: hook.call
        )
        let source = try SecureManagedPath(["ready"])
        let destination = try SecureManagedPath(["active"])
        let sourceURL = url(for: source)
        let destinationURL = url(for: destination)
        let outsideLink = temporaryDirectory.appendingPathComponent("outside-link")
        try Data("profile".utf8).write(to: sourceURL)
        hook.body = { boundary in
            guard boundary == .afterRename else { return }
            hook.body = nil
            guard link(destinationURL.path, outsideLink.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        XCTAssertThrowsError(
            try fileSystem.rename(from: source, to: destination)
        ) { error in
            XCTAssertEqual(
                error as? SecureManagedFileSystemError,
                .hardLinkEncountered
            )
        }
        XCTAssertEqual(try Data(contentsOf: outsideLink), Data("profile".utf8))
    }

    func testBoundaryHookSymlinkChangeAfterRenameIsRejectedWithoutFollowingIt() throws {
        let hook = SecureBoundaryHookBox()
        let fileSystem = try SecureManagedFileSystem(
            rootURL: managedRoot,
            boundaryHook: hook.call
        )
        let source = try SecureManagedPath(["ready"])
        let destination = try SecureManagedPath(["active"])
        let sourceURL = url(for: source)
        let destinationURL = url(for: destination)
        let displaced = temporaryDirectory.appendingPathComponent("displaced")
        let outside = temporaryDirectory.appendingPathComponent("outside")
        try Data("profile".utf8).write(to: sourceURL)
        try Data("outside".utf8).write(to: outside)
        hook.body = { boundary in
            guard boundary == .afterRename else { return }
            hook.body = nil
            try FileManager.default.moveItem(at: destinationURL, to: displaced)
            try FileManager.default.createSymbolicLink(
                at: destinationURL,
                withDestinationURL: outside
            )
        }

        XCTAssertThrowsError(
            try fileSystem.rename(from: source, to: destination)
        ) { error in
            XCTAssertEqual(
                error as? SecureManagedFileSystemError,
                .symbolicLinkEncountered
            )
        }
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
        XCTAssertEqual(try Data(contentsOf: displaced), Data("profile".utf8))
    }

    private func makeFileSystem() throws -> SecureManagedFileSystem {
        try SecureManagedFileSystem(rootURL: managedRoot)
    }

    private func createDirectoryOutsidePrimitive(at path: SecureManagedPath) throws {
        try FileManager.default.createDirectory(
            at: url(for: path),
            withIntermediateDirectories: true
        )
    }

    private func url(for path: SecureManagedPath) -> URL {
        path.components.reduce(managedRoot) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
    }
}

private final class SecureBoundaryHookBox: @unchecked Sendable {
    private let lock = NSLock()
    var body: ((SecureManagedFileSystemBoundary) throws -> Void)?

    var call: @Sendable (SecureManagedFileSystemBoundary) throws -> Void {
        { [self] boundary in
            let action = lock.withLock { body }
            try action?(boundary)
        }
    }
}

private extension SecureManagedItemState {
    var isPresent: Bool {
        if case .present = self {
            return true
        }
        return false
    }

    var identity: SecureManagedItemIdentity? {
        guard case let .present(identity) = self else {
            return nil
        }
        return identity
    }
}
