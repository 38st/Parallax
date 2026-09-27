import Darwin
import CryptoKit
import Foundation

extension SecureManagedFileSystem {
    func verifyRootIdentity() throws {
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

        if URL(fileURLWithPath: rootPath).pathComponents.contains(".parallax") {
            try Self.validateOwnedDirectory(descriptorStatus, descriptor: rootDescriptor, path: rootPath)
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

    func ensureDirectories(
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
                    relativeTo: descriptor,
                    requireOwnership: true
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

    func openParent(
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
                    relativeTo: descriptor,
                    requireOwnership: true
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

    func revalidateParent(
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

    func openDirectory(
        named name: String,
        relativeTo parent: Int32,
        requireOwnership: Bool = false
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
        do {
            var opened = stat()
            guard fstat(descriptor, &opened) == 0 else {
                throw Self.systemError("inspect opened managed directory", errno)
            }
            try validateDevice(opened)
            try Self.validateDirectoryLinks(descriptor)
            if requireOwnership {
                try Self.validateOwnedDirectory(opened, descriptor: descriptor, path: Self.directoryPath(descriptor))
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    func requireMissing(leaf: String, in parent: Int32) throws {
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

    func preflight(path: SecureManagedPath) throws -> stat {
        let (parent, leaf) = try openParent(of: path, createMissing: false)
        defer { close(parent) }
        return try preflightItem(parent: parent, name: leaf)
    }

    @discardableResult
    func preflightItem(
        parent: Int32,
        name: String,
        rootDevice: dev_t? = nil
    ) throws -> stat {
        var status = stat()
        guard fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw Self.mappedError(
                operation: "inspect managed item",
                code: errno,
                missing: .sourceMissing
            )
        }
        try validateDevice(status, expectedDevice: rootDevice)
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
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else {
            throw Self.systemError("inspect preflight directory", errno)
        }
        try validateDevice(opened, expectedDevice: rootDevice)
        guard Self.isSameObject(status, opened) else {
            throw SecureManagedFileSystemError.itemIdentityChanged
        }
        for child in try directoryEntryNames(descriptor) {
            try preflightItem(parent: descriptor, name: child, rootDevice: rootDevice)
        }
        return status
    }

    func directoryEntryNames(_ descriptor: Int32) throws -> [String] {
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

    func synchronize(
        _ descriptor: Int32,
        operation: String,
        barrier: Bool = true
    ) throws {
        var result: Int32
        repeat { result = systemCalls.sync(descriptor, barrier) } while result != 0 && errno == EINTR
        guard result == 0 else {
            throw Self.systemError(operation, errno)
        }
    }

    func sha256(_ descriptor: Int32) throws -> String {
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

    func performBoundary(
        _ boundary: SecureManagedFileSystemBoundary
    ) throws {
        try boundaryHook?(boundary)
    }
}
