import Darwin
import CryptoKit
import Foundation

extension SecureManagedFileSystem {
    func appendManifestEntries(
        parent: Int32,
        name: String,
        relativeComponents: [String],
        entries: inout [SecureManagedManifest.Entry],
        rootDevice: dev_t? = nil
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
        try validateDevice(inspectedStatus, expectedDevice: rootDevice)
        let identity = try Self.managedIdentity(from: inspectedStatus)
        switch identity.kind {
        case .regularFile:
            guard inspectedStatus.st_nlink == 1 else {
                throw SecureManagedFileSystemError.hardLinkEncountered
            }
            let flags = O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            try performBoundary(.beforeOpenFile(name, flags: flags))
            let descriptor = openat(
                parent,
                name,
                flags
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
            try validateDevice(openedStatus, expectedDevice: rootDevice)
            guard
                openedStatus.st_mode & S_IFMT == S_IFREG,
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
            try validateDevice(openedStatus, expectedDevice: rootDevice)
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
                    entries: &entries,
                    rootDevice: rootDevice
                )
            }
        }
    }
}
