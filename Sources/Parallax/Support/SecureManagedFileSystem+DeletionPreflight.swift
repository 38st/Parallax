import Darwin
import Foundation

extension SecureManagedFileSystem {
    func validateRemovableTree(at path: SecureManagedPath) throws {
        try verifyRootIdentity()
        let expected = try preflight(path: path)
        let (parent, leaf) = try openParent(of: path, createMissing: false)
        defer { close(parent) }
        try validateRemovalDirectory(parent)
        try validateRemovableItem(parent: parent, name: leaf, expected: expected)
        try revalidateParent(of: path, expectedDescriptor: parent)
        try verifyRootIdentity()
    }

    private func validateRemovalDirectory(_ descriptor: Int32) throws {
        guard faccessat(descriptor, ".", W_OK | X_OK, AT_EACCESS) == 0 else {
            throw Self.systemError("inspect managed deletion permissions", errno)
        }
    }

    private func validateRemovableItem(parent: Int32, name: String, expected: stat) throws {
        let descriptor = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw Self.mappedError(operation: "inspect managed deletion target", code: errno, missing: .sourceMissing)
        }
        defer { close(descriptor) }
        let status = try requireIdentity(parent: parent, name: name, descriptor: descriptor, expected: expected)
        try validateDevice(status)
        let identity = try Self.managedIdentity(from: status)
        let protectedFlags = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)
        guard status.st_flags & protectedFlags == 0 else {
            throw SecureManagedFileSystemError.unsupportedItem
        }
        if identity.kind == .directory {
            try validateRemovalDirectory(descriptor)
            for child in try directoryEntryNames(descriptor) {
                var childStatus = stat()
                guard fstatat(descriptor, child, &childStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw Self.systemError("inspect managed deletion child", errno)
                }
                try validateRemovableItem(parent: descriptor, name: child, expected: childStatus)
            }
        }
        try requireIdentity(parent: parent, name: name, descriptor: descriptor, expected: status)
    }
}
