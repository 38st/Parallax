import Darwin
import CryptoKit
import Foundation
/// Descriptor-relative filesystem primitives for managed profile transactions.
///
/// The root directory is opened once without following a leaf symlink. Every
/// walk below it uses `openat`/`fstatat` with no-follow semantics. Publication
/// uses `renameatx_np(..., RENAME_EXCL)`, so an unexpected destination can
/// never be overwritten.
final class SecureManagedFileSystem: @unchecked Sendable {
    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private let rootPath: String
    private let rootDescriptor: Int32
    private let rootIdentity: Identity
    private let boundaryHook:
        (@Sendable (SecureManagedFileSystemBoundary) throws -> Void)?

    init(
        rootURL: URL,
        boundaryHook:
            (@Sendable (SecureManagedFileSystemBoundary) throws -> Void)? = nil
    ) throws {
        let pinned = try Self.openExistingRoot(at: rootURL)
        rootPath = pinned.path
        rootDescriptor = pinned.descriptor
        rootIdentity = pinned.identity
        self.boundaryHook = boundaryHook
    }

    init(
        anchorURL: URL,
        rootComponents: [String],
        createIfMissing: Bool,
        boundaryHook:
            (@Sendable (SecureManagedFileSystemBoundary) throws -> Void)? = nil
    ) throws {
        _ = try SecureManagedPath(rootComponents)
        let anchor = try Self.openExistingRoot(at: anchorURL)
        var descriptor = anchor.descriptor
        do {
            for component in rootComponents {
                if createIfMissing {
                    if mkdirat(descriptor, component, 0o700) != 0 {
                        let code = errno
                        guard code == EEXIST else {
                            throw Self.mappedError(
                                operation: "create managed root component",
                                code: code,
                                missing: .invalidRoot
                            )
                        }
                    } else {
                        try Self.synchronizeDescriptor(
                            descriptor,
                            operation: "fsync managed root parent"
                        )
                    }
                }
                let next = openat(
                    descriptor,
                    component,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard next >= 0 else {
                    throw Self.mappedError(
                        operation: "open managed root component",
                        code: errno,
                        missing: .invalidRoot
                    )
                }
                close(descriptor)
                descriptor = next
            }

            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                throw Self.systemError("inspect managed root", errno)
            }
            let path = rootComponents.reduce(anchor.path) {
                URL(fileURLWithPath: $0)
                    .appendingPathComponent($1, isDirectory: true)
                    .path
            }
            var pathStatus = stat()
            guard
                lstat(path, &pathStatus) == 0,
                Self.isSameObject(status, pathStatus)
            else {
                throw SecureManagedFileSystemError.rootIdentityChanged
            }

            rootPath = path
            rootDescriptor = descriptor
            rootIdentity = Identity(
                device: status.st_dev,
                inode: status.st_ino
            )
            self.boundaryHook = boundaryHook
        } catch {
            close(descriptor)
            throw error
        }
    }

    deinit {
        close(rootDescriptor)
    }

    func createDirectory(
        at path: SecureManagedPath,
        permissions: mode_t = 0o700
    ) throws {
        try verifyRootIdentity()
        let descriptor = try ensureDirectories(
            path.components,
            finalMustBeNew: true,
            permissions: permissions
        )
        defer { close(descriptor) }
        try synchronize(descriptor, operation: "fsync created directory")
        try verifyRootIdentity()
    }

    func setDirectoryPermissions(
        at path: SecureManagedPath,
        permissions: mode_t
    ) throws {
        try verifyRootIdentity()
        let (parent, leaf) = try openParent(
            of: path,
            createMissing: false
        )
        defer { close(parent) }
        let descriptor = try openDirectory(
            named: leaf,
            relativeTo: parent
        )
        defer { close(descriptor) }
        guard fchmod(descriptor, permissions) == 0 else {
            throw Self.systemError(
                "set managed directory permissions",
                errno
            )
        }
        try synchronize(
            descriptor,
            operation: "fsync managed directory permissions"
        )
        try verifyRootIdentity()
    }

    func write(
        _ data: Data,
        to path: SecureManagedPath,
        permissions: mode_t = 0o600
    ) throws {
        try verifyRootIdentity()
        let (parent, leaf) = try openParent(of: path, createMissing: false)
        defer { close(parent) }

        let descriptor = openat(
            parent,
            leaf,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            permissions
        )
        guard descriptor >= 0 else {
            throw Self.mappedError(
                operation: "create managed file",
                code: errno,
                missing: .sourceMissing
            )
        }
        var descriptorIsOpen = true
        defer {
            if descriptorIsOpen {
                close(descriptor)
            }
        }

        do {
            try data.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else {
                    return
                }
                var written = 0
                while written < buffer.count {
                    let count = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: written),
                        buffer.count - written
                    )
                    guard count >= 0 else {
                        if errno == EINTR {
                            continue
                        }
                        throw Self.systemError("write managed file", errno)
                    }
                    written += count
                }
            }
            try synchronize(descriptor, operation: "fsync managed file")
            let closeResult = close(descriptor)
            descriptorIsOpen = false
            guard closeResult == 0 else {
                throw Self.systemError("close managed file", errno)
            }
            try synchronize(parent, operation: "fsync managed parent")
        } catch {
            _ = unlinkat(parent, leaf, 0)
            throw error
        }
        try verifyRootIdentity()
    }

    func itemState(
        at path: SecureManagedPath
    ) throws -> SecureManagedItemState {
        try verifyRootIdentity()
        let parentAndLeaf: (descriptor: Int32, leaf: String)
        do {
            parentAndLeaf = try openParent(of: path, createMissing: false)
        } catch SecureManagedFileSystemError.sourceMissing {
            return .missing
        }
        defer { close(parentAndLeaf.descriptor) }

        var status = stat()
        guard fstatat(
            parentAndLeaf.descriptor,
            parentAndLeaf.leaf,
            &status,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            if errno == ENOENT {
                return .missing
            }
            throw Self.mappedError(
                operation: "inspect managed item state",
                code: errno,
                missing: .sourceMissing
            )
        }
        return .present(try Self.managedIdentity(from: status))
    }

    func manifest(
        at path: SecureManagedPath
    ) throws -> SecureManagedManifest {
        try verifyRootIdentity()
        let (parent, leaf) = try openParent(of: path, createMissing: false)
        defer { close(parent) }
        var entries: [SecureManagedManifest.Entry] = []
        try appendManifestEntries(
            parent: parent,
            name: leaf,
            relativeComponents: [],
            entries: &entries
        )
        try verifyRootIdentity()
        return SecureManagedManifest(
            entries: entries.sorted {
                $0.relativeComponents.lexicographicallyPrecedes(
                    $1.relativeComponents
                )
            }
        )
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

    private func verifyRootIdentity() throws {
        var descriptorStatus = stat()
        guard fstat(rootDescriptor, &descriptorStatus) == 0 else {
            throw Self.systemError("fstat pinned managed root", errno)
        }
        guard
            (descriptorStatus.st_mode & S_IFMT) == S_IFDIR,
            Identity(
                device: descriptorStatus.st_dev,
                inode: descriptorStatus.st_ino
            ) == rootIdentity
        else {
            throw SecureManagedFileSystemError.rootIdentityChanged
        }

        var pathStatus = stat()
        guard lstat(rootPath, &pathStatus) == 0 else {
            throw SecureManagedFileSystemError.rootIdentityChanged
        }
        guard
            (pathStatus.st_mode & S_IFMT) == S_IFDIR,
            Identity(device: pathStatus.st_dev, inode: pathStatus.st_ino)
                == rootIdentity
        else {
            throw SecureManagedFileSystemError.rootIdentityChanged
        }
    }

    private func duplicateRootDescriptor() throws -> Int32 {
        let descriptor = fcntl(rootDescriptor, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else {
            throw Self.systemError("duplicate managed root descriptor", errno)
        }
        return descriptor
    }

    private func ensureDirectories(
        _ components: [String],
        finalMustBeNew: Bool,
        permissions: mode_t
    ) throws -> Int32 {
        var descriptor = try duplicateRootDescriptor()
        do {
            for (index, component) in components.enumerated() {
                let isFinal = index == components.count - 1
                let result = mkdirat(descriptor, component, permissions)
                if result != 0 {
                    let code = errno
                    if code == EEXIST, !(isFinal && finalMustBeNew) {
                        // Existing intermediate directories are opened below
                        // with no-follow semantics.
                    } else {
                        throw Self.mappedError(
                            operation: "create managed directory",
                            code: code,
                            missing: .sourceMissing
                        )
                    }
                } else {
                    try synchronize(
                        descriptor,
                        operation: "fsync created directory parent"
                    )
                }

                let next = try openDirectory(
                    named: component,
                    relativeTo: descriptor
                )
                close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func openParent(
        of path: SecureManagedPath,
        createMissing: Bool
    ) throws -> (descriptor: Int32, leaf: String) {
        guard let leaf = path.components.last else {
            throw SecureManagedFileSystemError.invalidPathComponent
        }
        let parents = Array(path.components.dropLast())
        if parents.isEmpty {
            return (try duplicateRootDescriptor(), leaf)
        }
        if createMissing {
            return (
                try ensureDirectories(
                    parents,
                    finalMustBeNew: false,
                    permissions: 0o700
                ),
                leaf
            )
        }

        var descriptor = try duplicateRootDescriptor()
        do {
            for component in parents {
                let next = try openDirectory(
                    named: component,
                    relativeTo: descriptor
                )
                close(descriptor)
                descriptor = next
            }
            return (descriptor, leaf)
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func revalidateParent(
        of path: SecureManagedPath,
        expectedDescriptor: Int32
    ) throws {
        let (currentDescriptor, _) = try openParent(
            of: path,
            createMissing: false
        )
        defer { close(currentDescriptor) }
        var expectedStatus = stat()
        var currentStatus = stat()
        guard
            fstat(expectedDescriptor, &expectedStatus) == 0,
            fstat(currentDescriptor, &currentStatus) == 0
        else {
            throw Self.systemError("inspect managed parent identity", errno)
        }
        guard Self.isSameObject(expectedStatus, currentStatus) else {
            throw SecureManagedFileSystemError.itemIdentityChanged
        }
    }

    private func openDirectory(
        named name: String,
        relativeTo parent: Int32
    ) throws -> Int32 {
        try performBoundary(.beforeOpenComponent(name))
        try verifyRootIdentity()
        let descriptor = openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            let code = errno
            if code == ELOOP || code == ENOTDIR {
                var status = stat()
                if fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) == 0,
                   (status.st_mode & S_IFMT) == S_IFLNK {
                    throw SecureManagedFileSystemError.symbolicLinkEncountered
                }
            }
            throw Self.mappedError(
                operation: "open managed directory",
                code: code,
                missing: .sourceMissing
            )
        }
        return descriptor
    }

    private func requireMissing(leaf: String, in parent: Int32) throws {
        var status = stat()
        if fstatat(parent, leaf, &status, AT_SYMLINK_NOFOLLOW) == 0 {
            throw SecureManagedFileSystemError.unexpectedDestination
        }
        guard errno == ENOENT else {
            throw Self.mappedError(
                operation: "inspect managed destination",
                code: errno,
                missing: .sourceMissing
            )
        }
    }

    private func preflight(path: SecureManagedPath) throws -> stat {
        let (parent, leaf) = try openParent(of: path, createMissing: false)
        defer { close(parent) }
        return try preflightItem(parent: parent, name: leaf)
    }

    @discardableResult
    private func preflightItem(parent: Int32, name: String) throws -> stat {
        var status = stat()
        guard fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw Self.mappedError(
                operation: "inspect managed item",
                code: errno,
                missing: .sourceMissing
            )
        }
        let kind = status.st_mode & S_IFMT
        if kind == S_IFLNK {
            throw SecureManagedFileSystemError.symbolicLinkEncountered
        }
        if kind == S_IFREG {
            guard status.st_nlink == 1 else {
                throw SecureManagedFileSystemError.hardLinkEncountered
            }
            return status
        }
        guard kind == S_IFDIR else {
            throw SecureManagedFileSystemError.unsupportedItem
        }

        let descriptor = try openDirectory(named: name, relativeTo: parent)
        defer { close(descriptor) }
        for child in try directoryEntryNames(descriptor) {
            try preflightItem(parent: descriptor, name: child)
        }
        return status
    }

    private func appendManifestEntries(
        parent: Int32,
        name: String,
        relativeComponents: [String],
        entries: inout [SecureManagedManifest.Entry]
    ) throws {
        var inspectedStatus = stat()
        guard fstatat(
            parent,
            name,
            &inspectedStatus,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            throw Self.mappedError(
                operation: "inspect manifest item",
                code: errno,
                missing: .sourceMissing
            )
        }
        let identity = try Self.managedIdentity(from: inspectedStatus)
        switch identity.kind {
        case .regularFile:
            guard inspectedStatus.st_nlink == 1 else {
                throw SecureManagedFileSystemError.hardLinkEncountered
            }
            let descriptor = openat(
                parent,
                name,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else {
                throw Self.mappedError(
                    operation: "open manifest file",
                    code: errno,
                    missing: .sourceMissing
                )
            }
            defer { close(descriptor) }
            var openedStatus = stat()
            guard fstat(descriptor, &openedStatus) == 0 else {
                throw Self.systemError("inspect manifest file", errno)
            }
            guard
                Self.isSameObject(inspectedStatus, openedStatus),
                openedStatus.st_nlink == 1
            else {
                throw SecureManagedFileSystemError.itemIdentityChanged
            }
            let digest = try sha256(descriptor)
            var finalStatus = stat()
            guard fstat(descriptor, &finalStatus) == 0 else {
                throw Self.systemError("reinspect manifest file", errno)
            }
            guard
                Self.isSameObject(openedStatus, finalStatus),
                openedStatus.st_size == finalStatus.st_size,
                openedStatus.st_mtimespec.tv_sec
                    == finalStatus.st_mtimespec.tv_sec,
                openedStatus.st_mtimespec.tv_nsec
                    == finalStatus.st_mtimespec.tv_nsec,
                finalStatus.st_nlink == 1
            else {
                throw SecureManagedFileSystemError.itemIdentityChanged
            }
            entries.append(
                SecureManagedManifest.Entry(
                    relativeComponents: relativeComponents,
                    kind: .regularFile,
                    byteCount: UInt64(max(0, finalStatus.st_size)),
                    permissions: UInt16(finalStatus.st_mode & 0o777),
                    sha256: digest
                )
            )
        case .directory:
            let descriptor = try openDirectory(
                named: name,
                relativeTo: parent
            )
            defer { close(descriptor) }
            var openedStatus = stat()
            guard fstat(descriptor, &openedStatus) == 0 else {
                throw Self.systemError("inspect manifest directory", errno)
            }
            guard Self.isSameObject(inspectedStatus, openedStatus) else {
                throw SecureManagedFileSystemError.itemIdentityChanged
            }
            entries.append(
                SecureManagedManifest.Entry(
                    relativeComponents: relativeComponents,
                    kind: .directory,
                    byteCount: 0,
                    permissions: UInt16(openedStatus.st_mode & 0o777),
                    sha256: nil
                )
            )
            for child in try directoryEntryNames(descriptor) {
                try appendManifestEntries(
                    parent: descriptor,
                    name: child,
                    relativeComponents: relativeComponents + [child],
                    entries: &entries
                )
            }
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

    private func removeItem(
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

    private func directoryEntryNames(_ descriptor: Int32) throws -> [String] {
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else {
            throw Self.systemError("duplicate directory descriptor", errno)
        }
        guard let directory = fdopendir(duplicate) else {
            let code = errno
            close(duplicate)
            throw Self.systemError("open directory stream", code)
        }
        defer { closedir(directory) }

        var names: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name: String? = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) { pointer in
                    let count = strnlen(pointer, Int(MAXNAMLEN) + 1)
                    let bytes = UnsafeRawBufferPointer(
                        start: pointer,
                        count: count
                    )
                    return String(bytes: bytes, encoding: .utf8)
                }
            }
            guard let name else {
                throw SecureManagedFileSystemError.invalidFileName
            }
            if name != ".", name != ".." {
                names.append(name)
            }
            errno = 0
        }
        guard errno == 0 else {
            throw Self.systemError("read directory stream", errno)
        }
        return names.sorted()
    }

    private func synchronize(
        _ descriptor: Int32,
        operation: String
    ) throws {
        try Self.synchronizeDescriptor(descriptor, operation: operation)
    }

    private func sha256(_ descriptor: Int32) throws -> String {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 {
                break
            }
            guard count > 0 else {
                if errno == EINTR {
                    continue
                }
                throw Self.systemError("read manifest file", errno)
            }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func performBoundary(
        _ boundary: SecureManagedFileSystemBoundary
    ) throws {
        try boundaryHook?(boundary)
    }

    private static func openExistingRoot(
        at rootURL: URL
    ) throws -> (path: String, descriptor: Int32, identity: Identity) {
        guard
            rootURL.isFileURL,
            rootURL.path.hasPrefix("/")
        else {
            throw SecureManagedFileSystemError.invalidRoot
        }

        let standardizedRoot = rootURL.standardizedFileURL
        var requestedStatus = stat()
        guard lstat(standardizedRoot.path, &requestedStatus) == 0 else {
            throw mappedError(
                operation: "lstat managed root",
                code: errno,
                missing: .invalidRoot
            )
        }
        guard (requestedStatus.st_mode & S_IFMT) != S_IFLNK else {
            throw SecureManagedFileSystemError.symbolicLinkEncountered
        }
        guard (requestedStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw SecureManagedFileSystemError.rootNotDirectory
        }

        guard let resolved = realpath(standardizedRoot.path, nil) else {
            throw mappedError(
                operation: "canonicalize managed root",
                code: errno,
                missing: .invalidRoot
            )
        }
        defer { free(resolved) }
        let canonicalPath = String(cString: resolved)
        let descriptor = open(
            canonicalPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw mappedError(
                operation: "open pinned managed root",
                code: errno,
                missing: .invalidRoot
            )
        }

        var descriptorStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0 else {
            let code = errno
            close(descriptor)
            throw systemError("fstat managed root", code)
        }
        var canonicalStatus = stat()
        guard
            lstat(canonicalPath, &canonicalStatus) == 0,
            isSameObject(requestedStatus, descriptorStatus),
            isSameObject(descriptorStatus, canonicalStatus),
            (descriptorStatus.st_mode & S_IFMT) == S_IFDIR
        else {
            close(descriptor)
            throw SecureManagedFileSystemError.rootIdentityChanged
        }
        return (
            canonicalPath,
            descriptor,
            Identity(
                device: descriptorStatus.st_dev,
                inode: descriptorStatus.st_ino
            )
        )
    }

    private static func managedIdentity(
        from status: stat
    ) throws -> SecureManagedItemIdentity {
        let kind: SecureManagedItemIdentity.Kind
        switch status.st_mode & S_IFMT {
        case S_IFDIR:
            kind = .directory
        case S_IFREG:
            guard status.st_nlink == 1 else {
                throw SecureManagedFileSystemError.hardLinkEncountered
            }
            kind = .regularFile
        case S_IFLNK:
            throw SecureManagedFileSystemError.symbolicLinkEncountered
        default:
            throw SecureManagedFileSystemError.unsupportedItem
        }
        return SecureManagedItemIdentity(
            volumeID: UInt64(truncatingIfNeeded: status.st_dev),
            fileID: UInt64(truncatingIfNeeded: status.st_ino),
            kind: kind
        )
    }

    private static func synchronizeDescriptor(
        _ descriptor: Int32,
        operation: String
    ) throws {
        guard fsync(descriptor) == 0 else {
            throw systemError(operation, errno)
        }
    }

    private static func mappedError(
        operation: String,
        code: Int32,
        missing: SecureManagedFileSystemError
    ) -> SecureManagedFileSystemError {
        switch code {
        case EEXIST:
            .unexpectedDestination
        case ELOOP:
            .symbolicLinkEncountered
        case ENOENT:
            missing
        default:
            systemError(operation, code)
        }
    }

    private static func isSameObject(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && (lhs.st_mode & S_IFMT) == (rhs.st_mode & S_IFMT)
    }

    private static func systemError(
        _ operation: String,
        _ code: Int32
    ) -> SecureManagedFileSystemError {
        .systemCall(operation: operation, code: code)
    }
}
