import Darwin
import CryptoKit
import Foundation

extension SecureManagedFileSystem {
    func copyTree(
        from source: SecureManagedPath,
        to destination: SecureManagedPath
    ) throws {
        try copyTree(from: source, to: destination, in: self)
    }

    func copyTree(
        from source: SecureManagedPath,
        to destination: SecureManagedPath,
        in destinationFileSystem: SecureManagedFileSystem
    ) throws {
        guard self !== destinationFileSystem || source != destination else {
            throw SecureManagedFileSystemError.sourceAndDestinationMatch
        }
        try verifyRootIdentity()
        try destinationFileSystem.verifyRootIdentity()
        let sourceManifestBefore = try manifest(at: source)
        let preflightStatus = try preflight(path: source)

        let (sourceParent, sourceLeaf) = try openParent(
            of: source,
            createMissing: false
        )
        defer { close(sourceParent) }
        let (destinationParent, destinationLeaf) =
            try destinationFileSystem.openParent(
            of: destination,
            createMissing: true
        )
        defer { close(destinationParent) }
        try destinationFileSystem.requireMissing(
            leaf: destinationLeaf,
            in: destinationParent
        )

        var sourceStatus = stat()
        guard fstatat(
            sourceParent,
            sourceLeaf,
            &sourceStatus,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            throw Self.mappedError(
                operation: "inspect copy source",
                code: errno,
                missing: .sourceMissing
            )
        }
        guard Self.isSameObject(preflightStatus, sourceStatus) else {
            throw SecureManagedFileSystemError.itemIdentityChanged
        }

        let sourceKind = sourceStatus.st_mode & S_IFMT
        if sourceKind == S_IFDIR {
            guard mkdirat(
                destinationParent,
                destinationLeaf,
                sourceStatus.st_mode & 0o777
            ) == 0 else {
                throw Self.mappedError(
                    operation: "create copy destination",
                    code: errno,
                    missing: .sourceMissing
                )
            }
        } else if sourceKind == S_IFREG {
            let descriptor = openat(
                destinationParent,
                destinationLeaf,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                sourceStatus.st_mode & 0o777
            )
            guard descriptor >= 0 else {
                throw Self.mappedError(
                    operation: "create copy destination",
                    code: errno,
                    missing: .sourceMissing
                )
            }
            close(descriptor)
        } else if sourceKind == S_IFLNK {
            throw SecureManagedFileSystemError.symbolicLinkEncountered
        } else {
            throw SecureManagedFileSystemError.unsupportedItem
        }

        do {
            try copyItem(
                sourceParent: sourceParent,
                sourceName: sourceLeaf,
                destinationParent: destinationParent,
                destinationName: destinationLeaf,
                sourceStatus: sourceStatus
            )
            try destinationFileSystem.synchronize(
                destinationParent,
                operation: "fsync copy destination parent"
            )
        } catch {
            try? destinationFileSystem.removeItem(
                parent: destinationParent,
                name: destinationLeaf,
                expectedStatus: nil
            )
            try? destinationFileSystem.synchronize(
                destinationParent,
                operation: "fsync copy cleanup parent"
            )
            throw error
        }
        try verifyRootIdentity()
        try destinationFileSystem.verifyRootIdentity()

        let sourceManifestAfter = try manifest(at: source)
        let destinationManifest = try destinationFileSystem.manifest(
            at: destination
        )
        guard
            sourceManifestBefore == sourceManifestAfter,
            sourceManifestBefore == destinationManifest
        else {
            let destinationState = try destinationFileSystem.itemState(
                at: destination
            )
            if case let .present(identity) = destinationState {
                try? destinationFileSystem.removeOwnedTree(
                    at: destination,
                    expectedIdentity: identity,
                    expectedManifest: destinationManifest
                )
            }
            throw SecureManagedFileSystemError.manifestMismatch
        }
    }

    private func copyItem(
        sourceParent: Int32,
        sourceName: String,
        destinationParent: Int32,
        destinationName: String,
        sourceStatus: stat
    ) throws {
        let kind = sourceStatus.st_mode & S_IFMT
        if kind == S_IFREG {
            guard sourceStatus.st_nlink == 1 else {
                throw SecureManagedFileSystemError.hardLinkEncountered
            }
            let source = openat(
                sourceParent,
                sourceName,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
            guard source >= 0 else {
                throw Self.mappedError(
                    operation: "open copy source",
                    code: errno,
                    missing: .sourceMissing
                )
            }
            defer { close(source) }
            var openedSourceStatus = stat()
            guard fstat(source, &openedSourceStatus) == 0 else {
                throw Self.systemError("inspect opened copy source", errno)
            }
            guard
                Self.isSameObject(sourceStatus, openedSourceStatus),
                openedSourceStatus.st_nlink == 1
            else {
                throw SecureManagedFileSystemError.itemIdentityChanged
            }
            let destination = openat(
                destinationParent,
                destinationName,
                O_WRONLY | O_NOFOLLOW | O_CLOEXEC
            )
            guard destination >= 0 else {
                throw Self.mappedError(
                    operation: "open copy destination",
                    code: errno,
                    missing: .sourceMissing
                )
            }
            defer { close(destination) }

            guard fcopyfile(source, destination, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else {
                throw Self.systemError("copy managed file", errno)
            }
            try synchronize(destination, operation: "fsync copied file")
            return
        }
        guard kind == S_IFDIR else {
            if kind == S_IFLNK {
                throw SecureManagedFileSystemError.symbolicLinkEncountered
            }
            throw SecureManagedFileSystemError.unsupportedItem
        }

        let source = try openDirectory(
            named: sourceName,
            relativeTo: sourceParent
        )
        defer { close(source) }
        var openedSourceStatus = stat()
        guard fstat(source, &openedSourceStatus) == 0 else {
            throw Self.systemError("inspect opened copy directory", errno)
        }
        guard Self.isSameObject(sourceStatus, openedSourceStatus) else {
            throw SecureManagedFileSystemError.itemIdentityChanged
        }
        let destination = try openDirectory(
            named: destinationName,
            relativeTo: destinationParent
        )
        defer { close(destination) }
        guard fchmod(destination, sourceStatus.st_mode & 0o777) == 0 else {
            throw Self.systemError(
                "preserve copied directory permissions",
                errno
            )
        }

        for child in try directoryEntryNames(source) {
            var childStatus = stat()
            guard fstatat(
                source,
                child,
                &childStatus,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                throw Self.mappedError(
                    operation: "inspect copy child",
                    code: errno,
                    missing: .sourceMissing
                )
            }
            let childKind = childStatus.st_mode & S_IFMT
            if childKind == S_IFLNK {
                throw SecureManagedFileSystemError.symbolicLinkEncountered
            }
            if childKind == S_IFREG, childStatus.st_nlink != 1 {
                throw SecureManagedFileSystemError.hardLinkEncountered
            }
            if childKind == S_IFDIR {
                guard mkdirat(
                    destination,
                    child,
                    childStatus.st_mode & 0o777
                ) == 0 else {
                    throw Self.mappedError(
                        operation: "create copied directory",
                        code: errno,
                        missing: .sourceMissing
                    )
                }
            } else if childKind == S_IFREG {
                let childDestination = openat(
                    destination,
                    child,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    childStatus.st_mode & 0o777
                )
                guard childDestination >= 0 else {
                    throw Self.mappedError(
                        operation: "create copied file",
                        code: errno,
                        missing: .sourceMissing
                    )
                }
                close(childDestination)
            } else {
                throw SecureManagedFileSystemError.unsupportedItem
            }
            try copyItem(
                sourceParent: source,
                sourceName: child,
                destinationParent: destination,
                destinationName: child,
                sourceStatus: childStatus
            )
        }
        try synchronize(destination, operation: "fsync copied directory")
    }
}
