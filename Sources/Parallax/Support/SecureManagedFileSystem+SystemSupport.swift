import Darwin
import CryptoKit
import Foundation

extension SecureManagedFileSystem {
    static func openExistingRoot(
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

    static func managedIdentity(
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

    static func synchronizeDescriptor(
        _ descriptor: Int32,
        operation: String
    ) throws {
        guard fsync(descriptor) == 0 else {
            throw systemError(operation, errno)
        }
    }

    static func mappedError(
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

    static func isSameObject(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && (lhs.st_mode & S_IFMT) == (rhs.st_mode & S_IFMT)
    }

    static func systemError(
        _ operation: String,
        _ code: Int32
    ) -> SecureManagedFileSystemError {
        .systemCall(operation: operation, code: code)
    }
}
