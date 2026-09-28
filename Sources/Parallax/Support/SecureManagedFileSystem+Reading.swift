import Darwin
import Foundation

extension SecureManagedFileSystem {
    /// Reads only a bounded, singly linked regular file beneath the pinned root.
    /// Revalidates its parent and timestamps before returning a snapshot.
    func readFile(at path: SecureManagedPath, maximumBytes: Int) throws -> Data {
        try verifyRootIdentity()
        let (parent, leaf) = try openParent(of: path, createMissing: false)
        defer { close(parent) }
        let flags = O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        try performBoundary(.beforeOpenFile(leaf, flags: flags))
        let descriptor = openat(parent, leaf, flags)
        guard descriptor >= 0 else {
            throw Self.mappedError(operation: "open managed snapshot", code: errno, missing: .sourceMissing)
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else {
            throw Self.systemError("inspect managed snapshot", errno)
        }
        try validateDevice(before)
        guard try Self.managedIdentity(from: before).kind == .regularFile,
              before.st_size >= 0, before.st_size <= maximumBytes else {
            throw SecureManagedFileSystemError.unsupportedItem
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw Self.systemError("read managed snapshot", errno) }
            if count == 0 { break }
            guard data.count <= maximumBytes - count else {
                throw SecureManagedFileSystemError.unsupportedItem
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        var named = stat()
        guard fstat(descriptor, &after) == 0,
              fstatat(parent, leaf, &named, AT_SYMLINK_NOFOLLOW) == 0,
              Self.isSameObject(before, after), Self.isSameObject(after, named),
              after.st_nlink == 1, before.st_size == after.st_size,
              data.count == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw SecureManagedFileSystemError.itemIdentityChanged
        }
        try revalidateParent(of: path, expectedDescriptor: parent)
        try verifyRootIdentity()
        return data
    }

    func directoryNames(at path: SecureManagedPath) throws -> [String] {
        try verifyRootIdentity()
        let (parent, leaf) = try openParent(of: path, createMissing: false)
        defer { close(parent) }
        let descriptor = try openDirectory(named: leaf, relativeTo: parent, requireOwnership: true)
        defer { close(descriptor) }
        let names = try directoryEntryNames(descriptor)
        try revalidateParent(of: path, expectedDescriptor: parent)
        var opened = stat()
        var named = stat()
        guard fstat(descriptor, &opened) == 0,
              fstatat(parent, leaf, &named, AT_SYMLINK_NOFOLLOW) == 0,
              Self.isSameObject(opened, named) else {
            throw SecureManagedFileSystemError.itemIdentityChanged
        }
        try verifyRootIdentity()
        return names
    }
}
