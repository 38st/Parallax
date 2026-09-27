import Darwin
import Foundation

typealias ApplicationRemovalTransactionIdentitySource =
    @Sendable (SecureManagedFileSystem) throws -> ApplicationRemovalTransactionRootIdentity

struct ApplicationRemovalTransactionRootIdentity: Sendable {
    let device: UInt64
    let inode: UInt64
    let volumeUUID: String?

    init(device: dev_t, inode: ino_t, volumeUUID: String?) {
        self.device = UInt64(truncatingIfNeeded: device)
        self.inode = UInt64(truncatingIfNeeded: inode)
        self.volumeUUID = volumeUUID
    }

    static func read(
        _ secure: SecureManagedFileSystem
    ) throws -> ApplicationRemovalTransactionRootIdentity {
        try secure.verifyRootIdentity()
        let volumeUUID = try readVolumeUUID(secure)
        try secure.verifyRootIdentity()
        return Self(
            device: secure.rootIdentity.device,
            inode: secure.rootIdentity.inode,
            volumeUUID: volumeUUID
        )
    }

    private static func readVolumeUUID(_ secure: SecureManagedFileSystem) throws -> String? {
        var volume = statfs()
        guard fstatfs(secure.rootDescriptor, &volume) == 0 else { return nil }
        let mountPath = withUnsafeBytes(of: &volume.f_mntonname) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let mount = open(mountPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard mount >= 0 else { return nil }
        defer { close(mount) }
        var status = stat()
        guard fstat(mount, &status) == 0,
              status.st_dev == secure.rootIdentity.device else { return nil }
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.volattr = UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_UUID)
        // getattrlist returns a four-byte length followed by the volume UUID.
        var buffer = [UInt8](repeating: 0, count: 20)
        let result = buffer.withUnsafeMutableBytes {
            fgetattrlist(mount, &attributes, $0.baseAddress, $0.count, 0)
        }
        let volumeUUID: String?
        if result == 0, buffer[4...].contains(where: { $0 != 0 }) {
            volumeUUID = UUID(uuid: (
                buffer[4], buffer[5], buffer[6], buffer[7],
                buffer[8], buffer[9], buffer[10], buffer[11],
                buffer[12], buffer[13], buffer[14], buffer[15],
                buffer[16], buffer[17], buffer[18], buffer[19]
            )).uuidString
        } else {
            volumeUUID = nil
        }
        return volumeUUID
    }
}

enum ApplicationRemovalTransactionFileSystem {
    static func isMountContainer(_ url: URL) -> Bool {
        ["/Volumes", "/System/Volumes", "/Network", "/Network/Volumes",
         "/Network/Servers", "/mnt", "/media"].contains(url.standardizedFileURL.path)
    }

    static func children(
        of path: SecureManagedPath,
        in secure: SecureManagedFileSystem
    ) throws -> [String] {
        try secure.verifyRootIdentity()
        let (parent, leaf) = try secure.openParent(of: path, createMissing: false)
        defer { close(parent) }
        let directory = try secure.openDirectory(named: leaf, relativeTo: parent)
        defer { close(directory) }
        let children = try secure.directoryEntryNames(directory)
        try secure.revalidateParent(of: path, expectedDescriptor: parent)
        try secure.verifyRootIdentity()
        return children
    }

    static func preflight(
        _ path: SecureManagedPath,
        in secure: SecureManagedFileSystem,
        profileName: String? = nil
    ) throws {
        do {
            _ = try secure.preflight(path: path)
        } catch SecureManagedFileSystemError.symbolicLinkEncountered {
            throw unsupportedTree(path, in: secure, profileName: profileName)
        } catch SecureManagedFileSystemError.hardLinkEncountered {
            throw unsupportedTree(path, in: secure, profileName: profileName)
        } catch SecureManagedFileSystemError.unsupportedItem {
            throw unsupportedTree(path, in: secure, profileName: profileName)
        }
    }

    private static func unsupportedTree(
        _ path: SecureManagedPath,
        in secure: SecureManagedFileSystem,
        profileName: String?
    ) -> ApplicationRemovalTransactionError {
        let item = (try? firstUnsupportedItem(path, in: secure)) ?? path
        let location = item.components.reduce(URL(fileURLWithPath: secure.rootPath)) {
            $0.appendingPathComponent($1)
        }
        return ApplicationRemovalTransactionError(
            code: .unsupportedProfileTree,
            profileName: profileName,
            itemPath: location.path
        )
    }

    private static func firstUnsupportedItem(
        _ path: SecureManagedPath,
        in secure: SecureManagedFileSystem
    ) throws -> SecureManagedPath? {
        do {
            if case .present(let identity) = try secure.itemState(at: path),
               identity.kind == .directory {
                for name in try children(of: path, in: secure) {
                    if let item = try firstUnsupportedItem(path.appending(name), in: secure) {
                        return item
                    }
                }
            }
        } catch SecureManagedFileSystemError.symbolicLinkEncountered {
            return path
        } catch SecureManagedFileSystemError.hardLinkEncountered {
            return path
        } catch SecureManagedFileSystemError.unsupportedItem {
            return path
        }
        return nil
    }
}
