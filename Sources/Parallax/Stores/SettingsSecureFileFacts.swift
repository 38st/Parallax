import Darwin

enum SettingsPrimaryLocation {
    static let fileName = "settings.json"
}

enum SettingsPrimaryACLDirective: Sendable, Equatable {
    case system
    case absent
    case present
    case failure(code: Int32)
}

struct SettingsFileIdentity: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
}

struct SettingsPrimaryFileMetadata: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case directory
        case regularFile
        case symbolicLink
        case other
    }

    var kind: Kind
    var device: UInt64
    var inode: UInt64
    var owner: UInt32
    var mode: UInt16
    var linkCount: UInt64
    var size: Int64
    var modificationSeconds: Int64
    var modificationNanoseconds: Int64
    var changeSeconds: Int64
    var changeNanoseconds: Int64

    var identity: SettingsFileIdentity {
        .init(device: device, inode: inode)
    }
}

enum SettingsPrimaryDescriptorACLResult: Sendable, Equatable {
    case absent
    case present
    case failure(code: Int32)
}

enum SettingsFileSecurityViolation: Sendable, Equatable {
    case wrongOwner
    case permissiveMode
    case specialMode
}

enum SettingsPrimaryDescriptorSecurity {
    static func metadata(
        from status: stat
    ) -> SettingsPrimaryFileMetadata {
        let type = status.st_mode & S_IFMT
        let kind: SettingsPrimaryFileMetadata.Kind
        switch type {
        case S_IFDIR:
            kind = .directory
        case S_IFREG:
            kind = .regularFile
        case S_IFLNK:
            kind = .symbolicLink
        default:
            kind = .other
        }
        return SettingsPrimaryFileMetadata(
            kind: kind,
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            owner: status.st_uid,
            mode: UInt16(status.st_mode & 0o7777),
            linkCount: UInt64(status.st_nlink),
            size: status.st_size,
            modificationSeconds: Int64(status.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            changeSeconds: Int64(status.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(status.st_ctimespec.tv_nsec)
        )
    }

    static func extendedACL(
        descriptor: Int32
    ) -> SettingsPrimaryDescriptorACLResult {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            let code = errno
            if code == ENOENT {
                return .absent
            }
            return .failure(code: code)
        }

        var entry: acl_entry_t?
        errno = 0
        let entryStatus = acl_get_entry(
            acl,
            ACL_FIRST_ENTRY.rawValue,
            &entry
        )
        let entryError = errno
        errno = 0
        let freeStatus = acl_free(UnsafeMutableRawPointer(acl))
        let freeError = errno
        guard freeStatus == 0 else {
            return .failure(code: freeError)
        }
        if entryStatus == 0 {
            return .present
        }
        if entryStatus == -1, entryError == EINVAL {
            return .absent
        }
        return .failure(code: entryError)
    }

    static func extendedACL(
        descriptor: Int32,
        directive: SettingsPrimaryACLDirective
    ) -> SettingsPrimaryDescriptorACLResult {
        switch directive {
        case .system:
            extendedACL(descriptor: descriptor)
        case .absent:
            .absent
        case .present:
            .present
        case .failure(let code):
            .failure(code: code)
        }
    }

    static func ownershipAndModeViolation(
        _ metadata: SettingsPrimaryFileMetadata
    ) -> SettingsFileSecurityViolation? {
        guard metadata.owner == geteuid() else {
            return .wrongOwner
        }
        guard metadata.mode & 0o077 == 0 else {
            return .permissiveMode
        }
        guard metadata.mode & 0o7000 == 0 else {
            return .specialMode
        }
        return nil
    }
}
