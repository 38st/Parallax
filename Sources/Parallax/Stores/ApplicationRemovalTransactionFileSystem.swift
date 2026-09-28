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
        let volumeUUID = try StorageVolumeIdentity.readVolumeUUID(secure)
        try secure.verifyRootIdentity()
        return Self(
            device: secure.rootIdentity.device,
            inode: secure.rootIdentity.inode,
            volumeUUID: volumeUUID
        )
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
