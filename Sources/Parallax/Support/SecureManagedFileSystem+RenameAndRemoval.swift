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

        let flags = O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        try performBoundary(.beforeOpenFile(sourceLeaf, flags: flags))
        let pinnedSource = openat(
            sourceParent,
            sourceLeaf,
            flags
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
        try validateDevice(pinnedStatus)
        guard Self.isSameObject(preflightStatus, pinnedStatus) else {
            throw SecureManagedFileSystemError.itemIdentityChanged
        }

        _ = try Self.managedIdentity(from: pinnedStatus)
        if pinnedStatus.st_mode & S_IFMT == S_IFDIR {
            try Self.validateDirectoryLinks(pinnedSource)
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

    struct RemovalManifest {
        let entries: [[String]: SecureManagedManifest.Entry]
        let children: [[String]: Set<String>]
        let allowMissing: Bool

        init(_ manifest: SecureManagedManifest, allowMissing: Bool = false) throws {
            var entries: [[String]: SecureManagedManifest.Entry] = [:]
            var children: [[String]: Set<String>] = [:]
            for entry in manifest.entries {
                guard entries.updateValue(entry, forKey: entry.relativeComponents) == nil else {
                    throw SecureManagedFileSystemError.manifestMismatch
                }
                if let name = entry.relativeComponents.last {
                    children[Array(entry.relativeComponents.dropLast()), default: []].insert(name)
                }
            }
            self.entries = entries
            self.children = children
            self.allowMissing = allowMissing
        }
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
        expectedStatus: stat?,
        rootDevice: dev_t? = nil,
        expectedManifest: RemovalManifest? = nil,
        relativeComponents: [String] = [],
        copyOwnership: CopyOwnership? = nil
    ) throws {
        if expectedStatus == nil {
            try preflightItem(parent: parent, name: name, rootDevice: rootDevice)
        }
        var status = stat()
        guard systemCalls.statusAt(parent, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw Self.mappedError(
                operation: "inspect removal target",
                code: errno,
                missing: .sourceMissing
            )
        }
        try validateDevice(status, expectedDevice: rootDevice)
        if let expectedStatus,
           !Self.isSameObject(expectedStatus, status) {
            throw SecureManagedFileSystemError.itemIdentityChanged
        }
        let kind = status.st_mode & S_IFMT
        if let expectedManifest {
            let identity = try Self.managedIdentity(from: status)
            guard let entry = expectedManifest.entries[relativeComponents],
                  entry.kind == identity.kind
            else {
                throw SecureManagedFileSystemError.manifestMismatch
            }
        }
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
        guard systemCalls.status(descriptor, &openedStatus) == 0 else {
            throw Self.systemError("inspect opened removal directory", errno)
        }
        try validateDevice(openedStatus, expectedDevice: rootDevice)
        guard Self.isSameObject(status, openedStatus) else {
            throw SecureManagedFileSystemError.itemIdentityChanged
        }
        let children = try directoryEntryNames(descriptor)
        if let expectedManifest {
            let expected = expectedManifest.children[relativeComponents] ?? []
            guard Set(children).isSubset(of: expected),
                  expectedManifest.allowMissing || Set(children) == expected
            else {
                throw SecureManagedFileSystemError.manifestMismatch
            }
        }
        let originalMode = openedStatus.st_mode & 0o7777
        let writableMode = originalMode | 0o700
        let restorationPath = originalMode != writableMode ? try Self.directoryPath(descriptor) : nil
        if originalMode != writableMode {
            guard systemCalls.changeMode(descriptor, writableMode) == 0 else {
                throw Self.systemError("prepare managed directory removal", errno)
            }
        }
        do {
            for child in children {
                let childOwnership = copyOwnership?.children[child]
                if copyOwnership != nil, childOwnership?.status == nil { continue }
                try removeItem(
                    parent: descriptor,
                    name: child,
                    expectedStatus: childOwnership?.status,
                    rootDevice: rootDevice,
                    expectedManifest: expectedManifest,
                    relativeComponents: relativeComponents + [child],
                    copyOwnership: childOwnership
                )
            }
            try synchronize(descriptor, operation: "fsync emptied directory", barrier: false)
            try requireIdentity(parent: parent, name: name, descriptor: descriptor, expected: status)
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else {
                throw Self.mappedError(
                    operation: "remove managed directory",
                    code: errno,
                    missing: .sourceMissing
                )
            }
        } catch {
            if let path = restorationPath {
                guard systemCalls.changeMode(descriptor, originalMode) == 0 else {
                    throw SecureManagedFileSystemError.permissionsRestoreFailed(path: path, code: errno)
                }
                try synchronize(descriptor, operation: "fsync restored directory permissions", barrier: false)
            }
            throw error
        }
    }
}
