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
        do {
            try validateDirectoryLinks(descriptor)
            if standardizedRoot.pathComponents.contains(".parallax") {
                try validateOwnedDirectory(descriptorStatus, descriptor: descriptor, path: canonicalPath)
            }
        } catch {
            close(descriptor)
            throw error
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

    static func validateDirectoryLinkCount(_ count: UInt32) throws {
        guard count == 1 else {
            throw SecureManagedFileSystemError.hardLinkEncountered
        }
    }

    static func validateDirectoryLinks(_ descriptor: Int32) throws {
        var volume = statfs()
        guard fstatfs(descriptor, &volume) == 0 else {
            throw systemError("inspect directory filesystem", errno)
        }
        let type = withUnsafePointer(to: &volume.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) {
                String(cString: $0)
            }
        }
        guard type == "hfs" else { return }
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.dirattr = attrgroup_t(ATTR_DIR_LINKCOUNT)
        var result = (UInt32(0), UInt32(0))
        guard fgetattrlist(
            descriptor,
            &attributes,
            &result,
            MemoryLayout.size(ofValue: result),
            0
        ) == 0 else {
            throw systemError("inspect directory hard links", errno)
        }
        guard result.0 == UInt32(MemoryLayout.size(ofValue: result)) else {
            throw SecureManagedFileSystemError.unsupportedItem
        }
        try validateDirectoryLinkCount(result.1)
    }

    static func directoryPath(_ descriptor: Int32) throws -> String {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &path) == 0 else {
            throw systemError("locate managed directory", errno)
        }
        return String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func validateOwnedDirectory(
        _ status: stat,
        descriptor: Int32,
        path: String
    ) throws {
        guard status.st_mode & S_IFMT == S_IFDIR, status.st_uid == geteuid() else {
            throw SecureManagedFileSystemError.unsafeDirectory(path: path)
        }
        // Never repair modes until ACLs have also been checked on this same descriptor.
        errno = 0
        if let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var entry: acl_entry_t?
            errno = 0
            let result = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry)
            guard result == -1, errno == EINVAL else {
                throw SecureManagedFileSystemError.unsafeDirectory(path: path)
            }
        } else if errno != ENOENT && errno != ENOTSUP && errno != EOPNOTSUPP {
            throw SecureManagedFileSystemError.unsafeDirectory(path: path)
        }
        guard status.st_mode & 0o022 != 0 else { return }
        let permissions = status.st_mode & 0o7777 & ~mode_t(0o022)
        guard fchmod(descriptor, permissions) == 0 else {
            throw SecureManagedFileSystemError.unsafeDirectory(path: path)
        }
        var repaired = stat()
        guard fstat(descriptor, &repaired) == 0,
              repaired.st_uid == geteuid(), repaired.st_mode & 0o022 == 0,
              isSameObject(status, repaired),
              synchronizeFileDescriptor(descriptor) == 0
        else {
            throw SecureManagedFileSystemError.unsafeDirectory(path: path)
        }
    }

    static func validateOwnedDirectory(at url: URL, expectedIdentity: FileSystemObjectIdentity?) throws {
        do {
            let descriptor = try openFileSystemItem(url, accessMode: O_RDONLY | O_DIRECTORY)
            defer { close(descriptor) }
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  expectedIdentity == FileSystemObjectIdentity(
                    volumeID: UInt64(truncatingIfNeeded: status.st_dev), fileID: UInt64(status.st_ino)
                  )
            else {
                throw SecureManagedFileSystemError.unsafeDirectory(path: url.path)
            }
            try validateOwnedDirectory(status, descriptor: descriptor, path: url.path)
        } catch {
            throw SecureManagedFileSystemError.unsafeDirectory(path: url.path)
        }
    }

    func validateDevice(_ status: stat, expectedDevice: dev_t? = nil) throws {
        guard status.st_dev == (expectedDevice ?? rootIdentity.device) else {
            throw SecureManagedFileSystemError.differentVolume
        }
    }

    @discardableResult
    func requireIdentity(
        parent: Int32,
        name: String,
        descriptor: Int32,
        expected: stat? = nil
    ) throws -> stat {
        var opened = stat()
        var named = stat()
        guard systemCalls.status(descriptor, &opened) == 0,
              systemCalls.statusAt(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0
        else {
            throw Self.systemError("reinspect managed item", errno)
        }
        try validateDevice(opened)
        try validateDevice(named)
        guard expected.map({ Self.isSameObject($0, opened) }) ?? true,
              Self.isSameObject(opened, named)
        else {
            throw SecureManagedFileSystemError.itemIdentityChanged
        }
        _ = try Self.managedIdentity(from: opened)
        if opened.st_mode & S_IFMT == S_IFDIR {
            try Self.validateDirectoryLinks(descriptor)
        }
        return opened
    }

    static func synchronizeDescriptor(
        _ descriptor: Int32,
        operation: String
    ) throws {
        guard synchronizeFileDescriptor(descriptor) == 0 else {
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
