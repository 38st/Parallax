import Darwin
import CryptoKit
import Foundation

extension SecureManagedFileSystem {
    final class CopyOwnership {
        var status: stat?
        var children: [String: CopyOwnership] = [:]
    }

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
        try verifyRootIdentity()
        try destinationFileSystem.verifyRootIdentity()
        let sourceComponents = URL(fileURLWithPath: rootPath).pathComponents
            + source.components
        let destinationComponents = URL(fileURLWithPath: destinationFileSystem.rootPath)
            .pathComponents + destination.components
        guard !sourceComponents.starts(with: destinationComponents),
              !destinationComponents.starts(with: sourceComponents)
        else {
            throw SecureManagedFileSystemError.sourceAndDestinationMatch
        }
        let sourceManifestBefore = try manifest(at: source)
        let preflightStatus = try preflight(path: source)
        try destinationFileSystem.rejectCopyIntoSource(
            preflightStatus,
            destination: destination
        )
        let (sourceParent, sourceLeaf) = try openParent(of: source, createMissing: false)
        defer { close(sourceParent) }
        let (destinationParent, destinationLeaf) = try destinationFileSystem.openParent(
            of: destination,
            createMissing: true
        )
        defer { close(destinationParent) }
        try destinationFileSystem.requireMissing(leaf: destinationLeaf, in: destinationParent)

        let ownership = CopyOwnership()
        var descriptor: Int32 = -1
        defer { if descriptor >= 0 { close(descriptor) } }
        do {
            let copied = try createCopyDestination(
                parent: destinationParent,
                name: destinationLeaf,
                sourceStatus: preflightStatus,
                in: destinationFileSystem,
                ownership: ownership
            )
            descriptor = copied.descriptor
            try copyItem(
                sourceParent: sourceParent,
                sourceName: sourceLeaf,
                destinationParent: destinationParent,
                destinationName: destinationLeaf,
                sourceStatus: preflightStatus,
                destinationDescriptor: copied.descriptor,
                destinationStatus: copied.status,
                destinationFileSystem: destinationFileSystem,
                ownership: ownership
            )
            try verifyRootIdentity()
            try destinationFileSystem.verifyRootIdentity()
            let sourceManifestAfter = try manifest(at: source)
            let destinationManifest = try destinationFileSystem.manifest(at: destination)
            guard sourceManifestBefore == sourceManifestAfter,
                  sourceManifestBefore == destinationManifest
            else {
                throw SecureManagedFileSystemError.manifestMismatch
            }
            // Every copied item has been fsynced; flush the device once before publication.
            try destinationFileSystem.synchronize(
                destinationParent,
                operation: "sync copy destination barrier"
            )
        } catch {
            let copyError = error
            if descriptor >= 0 {
                ownership.status = try? destinationFileSystem.requireIdentity(
                    parent: destinationParent, name: destinationLeaf, descriptor: descriptor
                )
            }
            var cleanupFailure: SecureManagedFileSystemError?
            do {
                try destinationFileSystem.verifyRootIdentity()
                if let status = ownership.status {
                    try destinationFileSystem.removeItem(
                        parent: destinationParent,
                        name: destinationLeaf,
                        expectedStatus: status,
                        copyOwnership: ownership
                    )
                }
            } catch let error as SecureManagedFileSystemError {
                cleanupFailure = error
            } catch {
                // The original copy failure remains the operation's result.
            }
            try? destinationFileSystem.synchronize(
                destinationParent,
                operation: "sync copy cleanup barrier"
            )
            if let cleanupFailure, case .permissionsRestoreFailed = cleanupFailure {
                throw cleanupFailure
            }
            throw copyError
        }
    }

    private func rejectCopyIntoSource(
        _ sourceStatus: stat,
        destination: SecureManagedPath
    ) throws {
        var descriptor = fcntl(rootDescriptor, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else {
            throw Self.systemError("inspect copy destination ancestry", errno)
        }
        defer { close(descriptor) }
        // Compare actual directory identities as well as path spellings. This
        // covers case aliases and separate handles pinned inside the source.
        for (index, component) in destination.components.enumerated() {
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                throw Self.systemError("inspect copy destination ancestor", errno)
            }
            guard !Self.isSameObject(sourceStatus, status) else {
                throw SecureManagedFileSystemError.sourceAndDestinationMatch
            }
            if index == destination.components.count - 1 { return }
            do {
                let next = try openDirectory(named: component, relativeTo: descriptor)
                close(descriptor)
                descriptor = next
            } catch SecureManagedFileSystemError.sourceMissing {
                return
            }
        }
    }

    private func createCopyDestination(
        parent: Int32,
        name: String,
        sourceStatus: stat,
        in destinationFileSystem: SecureManagedFileSystem,
        ownership: CopyOwnership
    ) throws -> (descriptor: Int32, status: stat) {
        try validateDevice(sourceStatus)
        let identity = try Self.managedIdentity(from: sourceStatus)
        let protectedFlags = UInt32(UF_IMMUTABLE | UF_APPEND) | ~UInt32(UF_SETTABLE)
        guard sourceStatus.st_flags & protectedFlags == 0 else {
            throw SecureManagedFileSystemError.unsupportedItem
        }
        var descriptor: Int32 = -1
        var created = stat()
        do {
            switch identity.kind {
            case .regularFile:
                descriptor = openat(
                    parent,
                    name,
                    O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    0o600
                )
                guard descriptor >= 0 else {
                    throw Self.mappedError(
                        operation: "create copied file",
                        code: errno,
                        missing: .sourceMissing
                    )
                }
                guard destinationFileSystem.systemCalls.status(descriptor, &created) == 0 else {
                    let code = errno
                    throw Self.systemError("inspect created copy file", code)
                }
            case .directory:
                guard mkdirat(parent, name, 0o700) == 0 else {
                    throw Self.mappedError(
                        operation: "create copied directory",
                        code: errno,
                        missing: .sourceMissing
                    )
                }
                guard destinationFileSystem.systemCalls.statusAt(parent, name, &created, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw Self.systemError("inspect created copy directory", errno)
                }
                ownership.status = created
                try destinationFileSystem.validateDevice(created)
                guard created.st_mode & S_IFMT == S_IFDIR else {
                    throw SecureManagedFileSystemError.itemIdentityChanged
                }
                try performBoundary(.afterCopyDestinationCreation(name))
                descriptor = try destinationFileSystem.openDirectory(named: name, relativeTo: parent)
            }
            ownership.status = created
            try destinationFileSystem.validateDevice(created)
            if identity.kind == .regularFile {
                try performBoundary(.afterCopyDestinationCreation(name))
            }
            try destinationFileSystem.requireIdentity(
                parent: parent, name: name, descriptor: descriptor, expected: created
            )
            return (descriptor, created)
        } catch {
            if descriptor >= 0 {
                // O_EXCL pins a newly created file. A reopened directory is not
                // trusted until it matches the identity captured after mkdirat.
                if identity.kind == .regularFile {
                    ownership.status = try? destinationFileSystem.requireIdentity(
                        parent: parent, name: name, descriptor: descriptor
                    )
                }
                close(descriptor)
            }
            throw error
        }
    }

    func copyItem(
        sourceParent: Int32,
        sourceName: String,
        destinationParent: Int32,
        destinationName: String,
        sourceStatus: stat,
        rootDevice: dev_t? = nil,
        destinationDescriptor: Int32,
        destinationStatus: stat,
        destinationFileSystem: SecureManagedFileSystem,
        ownership: CopyOwnership? = nil
    ) throws {
        defer {
            if let ownership {
                ownership.status = try? destinationFileSystem.requireIdentity(
                    parent: destinationParent, name: destinationName, descriptor: destinationDescriptor
                )
            }
        }
        try validateDevice(sourceStatus, expectedDevice: rootDevice)
        let targetFileSystem = destinationFileSystem
        let kind = sourceStatus.st_mode & S_IFMT
        if kind == S_IFREG {
            guard sourceStatus.st_nlink == 1 else {
                throw SecureManagedFileSystemError.hardLinkEncountered
            }
            let flags = O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            try performBoundary(.beforeOpenFile(sourceName, flags: flags))
            let source = openat(sourceParent, sourceName, flags)
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
            try validateDevice(openedSourceStatus, expectedDevice: rootDevice)
            guard Self.isSameObject(sourceStatus, openedSourceStatus),
                  openedSourceStatus.st_mode & S_IFMT == S_IFREG,
                  openedSourceStatus.st_nlink == 1
            else {
                throw SecureManagedFileSystemError.itemIdentityChanged
            }
            try targetFileSystem.requireIdentity(
                parent: destinationParent, name: destinationName,
                descriptor: destinationDescriptor, expected: destinationStatus
            )
            let protectedFlags = UInt32(UF_IMMUTABLE | UF_APPEND) | ~UInt32(UF_SETTABLE)
            guard openedSourceStatus.st_flags & protectedFlags == 0 else {
                throw SecureManagedFileSystemError.unsupportedItem
            }
            let copyResult = fcopyfile(
                source,
                destinationDescriptor,
                nil,
                copyfile_flags_t(COPYFILE_ALL)
            )
            let copyError = errno
            // A source can gain flags during the copy. Never leave an undeletable copy.
            var copiedStatus = stat()
            guard fstat(destinationDescriptor, &copiedStatus) == 0 else {
                throw Self.systemError("inspect copied file flags", errno)
            }
            if copiedStatus.st_flags & protectedFlags != 0,
               fchflags(destinationDescriptor, copiedStatus.st_flags & ~protectedFlags) != 0 {
                throw Self.systemError("clear protected copied file flags", errno)
            }
            guard copyResult == 0 else {
                throw Self.systemError("copy managed file", copyError)
            }
            guard fchmod(destinationDescriptor, sourceStatus.st_mode & 0o777) == 0 else {
                throw Self.systemError("preserve copied file permissions", errno)
            }
            try targetFileSystem.requireIdentity(
                parent: destinationParent, name: destinationName,
                descriptor: destinationDescriptor
            )
            try targetFileSystem.synchronize(destinationDescriptor, operation: "fsync copied file", barrier: false)
            return
        }
        guard kind == S_IFDIR else {
            if kind == S_IFLNK { throw SecureManagedFileSystemError.symbolicLinkEncountered }
            throw SecureManagedFileSystemError.unsupportedItem
        }
        let source = try openDirectory(named: sourceName, relativeTo: sourceParent)
        defer { close(source) }
        var openedSourceStatus = stat()
        guard fstat(source, &openedSourceStatus) == 0 else {
            throw Self.systemError("inspect opened copy directory", errno)
        }
        try validateDevice(openedSourceStatus, expectedDevice: rootDevice)
        guard Self.isSameObject(sourceStatus, openedSourceStatus) else {
            throw SecureManagedFileSystemError.itemIdentityChanged
        }
        try targetFileSystem.requireIdentity(
            parent: destinationParent, name: destinationName,
            descriptor: destinationDescriptor, expected: destinationStatus
        )
        for child in try directoryEntryNames(source) {
            var childStatus = stat()
            guard fstatat(source, child, &childStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw Self.mappedError(
                    operation: "inspect copy child",
                    code: errno,
                    missing: .sourceMissing
                )
            }
            try validateDevice(childStatus, expectedDevice: rootDevice)
            let childOwnership = CopyOwnership()
            ownership?.children[child] = childOwnership
            let copied = try createCopyDestination(
                parent: destinationDescriptor,
                name: child,
                sourceStatus: childStatus,
                in: targetFileSystem,
                ownership: childOwnership
            )
            defer { close(copied.descriptor) }
            try copyItem(
                sourceParent: source, sourceName: child,
                destinationParent: destinationDescriptor, destinationName: child,
                sourceStatus: childStatus, rootDevice: rootDevice,
                destinationDescriptor: copied.descriptor, destinationStatus: copied.status,
                destinationFileSystem: targetFileSystem,
                ownership: childOwnership
            )
        }
        // Copy metadata through the pinned descriptors, never through paths.
        guard fstat(source, &openedSourceStatus) == 0 else {
            throw Self.systemError("inspect copy directory flags", errno)
        }
        let protectedFlags = UInt32(UF_IMMUTABLE | UF_APPEND) | ~UInt32(UF_SETTABLE)
        guard openedSourceStatus.st_flags & protectedFlags == 0 else {
            throw SecureManagedFileSystemError.unsupportedItem
        }
        guard fcopyfile(source, destinationDescriptor, nil, copyfile_flags_t(COPYFILE_XATTR)) == 0 else {
            throw Self.systemError("preserve copied directory attributes", errno)
        }
        guard fchflags(destinationDescriptor, openedSourceStatus.st_flags & ~protectedFlags) == 0 else {
            throw Self.systemError("preserve copied directory flags", errno)
        }
        guard fchmod(destinationDescriptor, sourceStatus.st_mode & 0o777) == 0 else {
            throw Self.systemError("preserve copied directory permissions", errno)
        }
        try targetFileSystem.requireIdentity(
            parent: destinationParent, name: destinationName,
            descriptor: destinationDescriptor
        )
        try targetFileSystem.synchronize(destinationDescriptor, operation: "fsync copied directory", barrier: false)
    }
}
