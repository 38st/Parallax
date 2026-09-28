import Foundation

struct StorageTransactionRootBinding: Codable, Equatable {
    let path: String
    let volumeID: UInt64
    let fileID: UInt64
    var identityVersion: Int? = nil
    var volumeUUID: String? = nil

    var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    var identity: FileSystemObjectIdentity {
        FileSystemObjectIdentity(volumeID: volumeID, fileID: fileID)
    }

    var isValid: Bool {
        path.hasPrefix("/") && !path.contains("\0") && path == url.standardizedFileURL.path
            && (identityVersion == nil || identityVersion == 1)
            && (volumeUUID == nil || volumeUUID.flatMap(UUID.init(uuidString:)) != nil)
    }

    func matches(_ current: StorageVolumeIdentity) -> Bool {
        guard isValid, current.inode == fileID else { return false }
        guard identityVersion == 1, let recorded = volumeUUID else { return current.device == volumeID }
        if let actual = current.volumeUUID {
            return recorded.caseInsensitiveCompare(actual) == .orderedSame
        }
        // UUID-less filesystems retain inode and transaction ownership checks.
        return true
    }

    static func capture(_ url: URL, identitySource: StorageVolumeIdentitySource) throws -> Self {
        let secure = try SecureManagedFileSystem(rootURL: url)
        let identity = try identitySource(secure)
        return Self(path: url.path, volumeID: identity.device, fileID: identity.inode,
            identityVersion: 1, volumeUUID: identity.volumeUUID)
    }
}
