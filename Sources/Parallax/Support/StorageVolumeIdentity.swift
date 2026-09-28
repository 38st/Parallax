import Darwin
import Foundation

typealias StorageVolumeIdentitySource = @Sendable (SecureManagedFileSystem) throws -> StorageVolumeIdentity

struct StorageVolumeIdentity: Sendable {
    let device: UInt64
    let inode: UInt64
    let volumeUUID: String?

    static func read(_ secure: SecureManagedFileSystem) throws -> Self {
        try secure.verifyRootIdentity()
        let uuid = try readVolumeUUID(secure)
        try secure.verifyRootIdentity()
        return Self(device: UInt64(bitPattern: Int64(secure.rootIdentity.device)),
            inode: UInt64(secure.rootIdentity.inode), volumeUUID: uuid)
    }

    static func readVolumeUUID(_ secure: SecureManagedFileSystem) throws -> String? {
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
