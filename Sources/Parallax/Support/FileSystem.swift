import Foundation
import Darwin

struct FileSystemObjectIdentity: Sendable, Equatable, Hashable {
    let volumeID: UInt64
    let fileID: UInt64
}

struct FileSystemItemAttributes: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case directory
        case regularFile
        case symbolicLink
        case other
    }

    var kind: Kind
    var size: UInt64?
    var modificationDate: Date?
    var posixPermissions: Int?
    var identity: FileSystemObjectIdentity?
}

/// The filesystem operations Parallax uses for library persistence and profile data.
///
/// Keeping this interface URL-based makes failure behavior independently testable and
/// gives later path-containment and transaction work one boundary to harden.
protocol FileSystem: Sendable {
    func fileExists(at url: URL) -> Bool
    func attributesOfItem(at url: URL) throws -> FileSystemItemAttributes
    func canonicalURL(for url: URL) throws -> URL
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws
    func removeItem(at url: URL) throws
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func readData(at url: URL) throws -> Data
    func writeData(_ data: Data, to url: URL) throws
    func writeDataAtomically(_ data: Data, to url: URL) throws
    func replaceItem(at destinationURL: URL, withItemAt sourceURL: URL) throws
    func setPOSIXPermissions(_ permissions: Int, at url: URL) throws
    func destinationOfSymbolicLink(at url: URL) throws -> String
    func synchronize(at url: URL) throws
    func applicationSupportURL(create: Bool) throws -> URL
}

extension FileSystem {
    func setPOSIXPermissions(_ permissions: Int, at url: URL) throws {
        guard chmod(url.path, mode_t(permissions)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func destinationOfSymbolicLink(at url: URL) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink(url.path, &buffer, Int(PATH_MAX))
        guard count >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return String(decoding: buffer.prefix(Int(count)).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    func synchronize(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

struct LocalFileSystem: FileSystem, @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func attributesOfItem(at url: URL) throws -> FileSystemItemAttributes {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let kind: FileSystemItemAttributes.Kind
        switch attributes[.type] as? FileAttributeType {
        case .typeDirectory:
            kind = .directory
        case .typeRegular:
            kind = .regularFile
        case .typeSymbolicLink:
            kind = .symbolicLink
        default:
            kind = .other
        }
        return FileSystemItemAttributes(
            kind: kind,
            size: (attributes[.size] as? NSNumber)?.uint64Value,
            modificationDate: attributes[.modificationDate] as? Date,
            posixPermissions: (attributes[.posixPermissions] as? NSNumber)?.intValue,
            identity: fileIdentity(from: attributes)
        )
    }

    func canonicalURL(for url: URL) throws -> URL {
        guard let resolvedPath = realpath(url.path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(resolvedPath) }
        return URL(fileURLWithPath: String(cString: resolvedPath))
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try rejectSymbolicLinkAncestors(
            of: url,
            includeLeaf: false
        )
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: withIntermediateDirectories
        )
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try rejectSymbolicLinkAncestors(
            of: destinationURL,
            includeLeaf: false
        )
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try rejectSymbolicLinkAncestors(
            of: sourceURL,
            includeLeaf: false
        )
        try rejectSymbolicLinkAncestors(
            of: destinationURL,
            includeLeaf: false
        )
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    func removeItem(at url: URL) throws {
        try rejectSymbolicLinkAncestors(of: url, includeLeaf: false)
        try fileManager.removeItem(at: url)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        )
    }

    func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func writeData(_ data: Data, to url: URL) throws {
        try rejectSymbolicLinkAncestors(of: url, includeLeaf: false)
        try data.write(to: url, options: [.withoutOverwriting])
    }

    func writeDataAtomically(_ data: Data, to url: URL) throws {
        try rejectSymbolicLinkAncestors(of: url, includeLeaf: false)
        try data.write(to: url, options: [.atomic])
    }

    func replaceItem(at destinationURL: URL, withItemAt sourceURL: URL) throws {
        try rejectSymbolicLinkAncestors(
            of: destinationURL,
            includeLeaf: false
        )
        try rejectSymbolicLinkAncestors(
            of: sourceURL,
            includeLeaf: false
        )
        if fileExists(at: destinationURL) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: sourceURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        }
    }

    func setPOSIXPermissions(_ permissions: Int, at url: URL) throws {
        try rejectSymbolicLinkAncestors(of: url, includeLeaf: false)
        try fileManager.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    func destinationOfSymbolicLink(at url: URL) throws -> String {
        try fileManager.destinationOfSymbolicLink(atPath: url.path)
    }

    func synchronize(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func applicationSupportURL(create: Bool) throws -> URL {
        try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: create
        )
    }

    private func fileIdentity(
        from attributes: [FileAttributeKey: Any]
    ) -> FileSystemObjectIdentity? {
        guard
            let volumeID = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
            let fileID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        else {
            return nil
        }
        return FileSystemObjectIdentity(volumeID: volumeID, fileID: fileID)
    }

    private func rejectSymbolicLinkAncestors(
        of url: URL,
        includeLeaf: Bool
    ) throws {
        let inspected = (
            includeLeaf ? url : url.deletingLastPathComponent()
        ).standardizedFileURL
        let components = inspected.pathComponents
        guard inspected.path.hasPrefix("/"), components.count >= 2 else {
            throw POSIXError(.EINVAL)
        }

        for count in 2...components.count {
            let candidatePath = NSString.path(
                withComponents: Array(components.prefix(count))
            )
            var status = stat()
            if lstat(candidatePath, &status) != 0 {
                if errno == ENOENT {
                    return
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if (status.st_mode & S_IFMT) == S_IFLNK {
                guard isTrustedSystemRootAlias(candidatePath) else {
                    throw POSIXError(.ELOOP)
                }
            }
        }
    }

    private func isTrustedSystemRootAlias(_ path: String) -> Bool {
        let expectedTargets = [
            "/var": "private/var",
            "/tmp": "private/tmp",
            "/etc": "private/etc",
        ]
        guard let expected = expectedTargets[path] else {
            return false
        }
        return (try? fileManager.destinationOfSymbolicLink(atPath: path))
            == expected
    }
}
