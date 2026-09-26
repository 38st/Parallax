import Darwin
import CryptoKit
import Foundation

extension SecureManagedFileSystem {
    func rename(
        from source: SecureManagedPath,
        to destination: SecureManagedPath
    ) throws {
        guard source != destination else {
            throw SecureManagedFileSystemError.sourceAndDestinationMatch
        }
        try verifyRootIdentity()
        let preflightStatus = try preflight(path: source)
        let (sourceParent, sourceLeaf) = try openParent(
            of: source,
            createMissing: false
        )
        defer { close(sourceParent) }
        let (destinationParent, destinationLeaf) = try openParent(
            of: destination,
            createMissing: true
        )
        defer { close(destinationParent) }
        try requireMissing(leaf: destinationLeaf, in: destinationParent)

        let pinnedSource = openat(
            sourceParent,
            sourceLeaf,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard pinnedSource >= 0 else {
            throw Self.mappedError(
                operation: "pin rename source",
                code: errno,
                missing: .sourceMissing
            )
        }
        defer { close(pinnedSource) }
        var pinnedStatus = stat()
        guard fstat(pinnedSource, &pinnedStatus) == 0 else {
            throw Self.systemError("inspect pinned rename source", errno)
        }
        guard Self.isSameObject(preflightStatus, pinnedStatus) else {
            throw SecureManagedFileSystemError.itemIdentityChanged
        }

        try performBoundary(.beforeRename)
        try verifyRootIdentity()
        try revalidateParent(of: source, expectedDescriptor: sourceParent)
        try revalidateParent(
            of: destination,
            expectedDescriptor: destinationParent
        )
        guard renameatx_np(
            sourceParent,
            sourceLeaf,
            destinationParent,
            destinationLeaf,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw Self.mappedError(
                operation: "publish managed item",
                code: errno,
                missing: .sourceMissing
            )
        }
        try performBoundary(.afterRename)
        var publishedStatus = stat()
        let publicationInspected = fstatat(
            destinationParent,
            destinationLeaf,
            &publishedStatus,
            AT_SYMLINK_NOFOLLOW
        ) == 0
        if publicationInspected,
           (publishedStatus.st_mode & S_IFMT) == S_IFLNK {
            throw SecureManagedFileSystemError.symbolicLinkEncountered
        }
        if publicationInspected,
           (publishedStatus.st_mode & S_IFMT) == S_IFREG,
           publishedStatus.st_nlink != 1 {
            _ = renameatx_np(
                destinationParent,
                destinationLeaf,
                sourceParent,
                sourceLeaf,
                UInt32(RENAME_EXCL)
            )
            try? synchronize(
                sourceParent,
                operation: "fsync rename identity rollback source"
            )
            try? synchronize(
                destinationParent,
                operation: "fsync rename hardlink rollback destination"
            )
            throw SecureManagedFileSystemError.hardLinkEncountered
        }
        guard
            publicationInspected,
            Self.isSameObject(pinnedStatus, publishedStatus)
        else {
            throw SecureManagedFileSystemError.itemIdentityChanged
        }
        try synchronize(sourceParent, operation: "fsync rename source parent")
        if sourceParent != destinationParent {
            try synchronize(
                destinationParent,
                operation: "fsync rename destination parent"
            )
        }
        try verifyRootIdentity()
    }

    func removeTree(at path: SecureManagedPath) throws {
        try verifyRootIdentity()
        let preflightStatus = try preflight(path: path)
        let (parent, leaf) = try openParent(of: path, createMissing: false)
        defer { close(parent) }
        try removeItem(
            parent: parent,
            name: leaf,
            expectedStatus: preflightStatus
        )
        try synchronize(parent, operation: "fsync remove parent")
        try verifyRootIdentity()
    }

    func removeItem(
        parent: Int32,
        name: String,
        expectedStatus: stat?
    ) throws {
        if expectedStatus == nil {
            try preflightItem(parent: parent, name: name)
        }
        var status = stat()
        guard fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw Self.mappedError(
                operation: "inspect removal target",
                code: errno,
                missing: .sourceMissing
            )
        }
        if let expectedStatus,
           !Self.isSameObject(expectedStatus, status) {
            throw SecureManagedFileSystemError.itemIdentityChanged
        }
        let kind = status.st_mode & S_IFMT
        if kind == S_IFLNK {
            throw SecureManagedFileSystemError.symbolicLinkEncountered
        }
        if kind == S_IFREG {
            guard status.st_nlink == 1 else {
                throw SecureManagedFileSystemError.hardLinkEncountered
            }
            guard unlinkat(parent, name, 0) == 0 else {
                throw Self.mappedError(
                    operation: "remove managed file",
                    code: errno,
                    missing: .sourceMissing
                )
            }
            return
        }
        guard kind == S_IFDIR else {
            throw SecureManagedFileSystemError.unsupportedItem
        }

        let descriptor = try openDirectory(named: name, relativeTo: parent)
        defer { close(descriptor) }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0 else {
            throw Self.systemError("inspect opened removal directory", errno)
        }
        guard Self.isSameObject(status, openedStatus) else {
            throw SecureManagedFileSystemError.itemIdentityChanged
        }
        for child in try directoryEntryNames(descriptor) {
            try removeItem(
                parent: descriptor,
                name: child,
                expectedStatus: nil
            )
        }
        try synchronize(descriptor, operation: "fsync emptied directory")
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else {
            throw Self.mappedError(
                operation: "remove managed directory",
                code: errno,
                missing: .sourceMissing
            )
        }
    }
}
