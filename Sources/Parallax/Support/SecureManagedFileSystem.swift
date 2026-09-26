import Darwin
import CryptoKit
import Foundation
/// Descriptor-relative filesystem primitives for managed profile transactions.
///
/// The root directory is opened once without following a leaf symlink. Every
/// walk below it uses `openat`/`fstatat` with no-follow semantics. Publication
/// uses `renameatx_np(..., RENAME_EXCL)`, so an unexpected destination can
/// never be overwritten.
final class SecureManagedFileSystem: Sendable {
    struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    let rootPath: String
    let rootDescriptor: Int32
    let rootIdentity: Identity
    let boundaryHook:
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
}
