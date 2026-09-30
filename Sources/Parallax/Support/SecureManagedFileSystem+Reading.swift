import Darwin
import Foundation

extension SecureManagedFileSystem {
    /// Reads a singly linked regular file beneath the pinned root, revalidating
    /// its parent and timestamps. Uncapped history reads use private disk-backed
    /// snapshots; bounded callers retain their existing in-memory read policy.
    func readFile(at path: SecureManagedPath, maximumBytes: Int? = nil) throws -> Data {
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
              before.st_size >= 0 else {
            throw SecureManagedFileSystemError.unsupportedItem
        }
        if let maximumBytes, before.st_size > maximumBytes {
            throw SecureManagedFileSystemError.fileTooLarge(maximumBytes: maximumBytes)
        }
        let scratch = maximumBytes == nil ? try HistoryFileBuffer() : nil
        var data = Data()
        var byteCount = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw Self.systemError("read managed snapshot", errno) }
            if count == 0 { break }
            if let maximumBytes, byteCount > maximumBytes - count {
                throw SecureManagedFileSystemError.fileTooLarge(maximumBytes: maximumBytes)
            }
            if let scratch {
                try buffer.withUnsafeBytes { try scratch.append(UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
            } else {
                data.append(contentsOf: buffer.prefix(count))
            }
            byteCount += count
        }
        var after = stat()
        var named = stat()
        guard fstat(descriptor, &after) == 0,
              fstatat(parent, leaf, &named, AT_SYMLINK_NOFOLLOW) == 0,
              Self.isSameObject(before, after), Self.isSameObject(after, named),
              after.st_nlink == 1, before.st_size == after.st_size,
              byteCount == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw SecureManagedFileSystemError.itemIdentityChanged
        }
        try revalidateParent(of: path, expectedDescriptor: parent)
        try verifyRootIdentity()
        return try scratch?.finish() ?? data
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
